#!/usr/bin/env python3
"""
Parse a .nettrace file (EventPipe format) and extract GC events.
Outputs: gen0_count, gen1_count, gen2_count, total_gc, first_ts, last_ts (duration)

Usage: python3 parse_nettrace_gc.py <file.nettrace>
"""

import sys
import struct
import io
import os

def read_varint(buf, pos):
    """Read a variable-length int (7 bits per byte, LSB first)."""
    result = 0
    shift = 0
    while pos < len(buf):
        b = buf[pos]; pos += 1
        result |= (b & 0x7F) << shift
        shift += 7
        if not (b & 0x80):
            break
    return result, pos

def read_string(buf, pos):
    """Read a null-terminated UTF-16 string (prefixed by uint16 len in chars)."""
    if pos + 2 > len(buf):
        return "", pos
    length = struct.unpack_from('<H', buf, pos)[0]; pos += 2
    if length == 0:
        return "", pos
    s = buf[pos:pos + length * 2].decode('utf-16-le', errors='replace')
    pos += length * 2
    return s, pos

def read_string_utf8_nul(buf, pos):
    """Read null-terminated UTF-8 string."""
    end = buf.index(b'\x00', pos)
    s = buf[pos:end].decode('utf-8', errors='replace')
    return s, end + 1

# EventPipe tag constants
TAG_NULL = 1
TAG_OBJECT = 5
TAG_END_OBJECT = 6
TAG_FORWARD_REF = 7

# Object type IDs
TYPE_TRACE = 1
TYPE_THREAD = 2
TYPE_STACK = 3
TYPE_BLOB = 4
TYPE_KEYWORD = 5

# GC event IDs in Microsoft-Windows-DotNETRuntime
GC_START_ID = 1
GC_END_ID = 2
GC_HEAP_STATS_ID = 4
GC_SUSPEND_EE_ID = 9
GC_RESTART_EE_ID = 3

def parse_nettrace(path):
    with open(path, 'rb') as f:
        data = f.read()

    # Validate header
    if not data.startswith(b'Nettrace'):
        print("ERROR: Not a nettrace file", file=sys.stderr)
        return None

    # Skip "Nettrace" (8 bytes) + FastSerialization header string
    # Format: "!FastSerialization.1\n" or "!FastSerialization.1"
    pos = 8
    # Read the FastSerialization header as null-terminated ASCII
    # Actually it's prefixed by length as 4-byte little-endian int
    hdr_len = struct.unpack_from('<I', data, pos)[0]; pos += 4
    hdr_str = data[pos:pos+hdr_len].decode('ascii', errors='replace'); pos += hdr_len

    # Now we're in the stream of objects
    # Track metadata: metadataId -> (provider_name, event_id, event_name, fields)
    metadata = {}
    gc_events = []  # list of (timestamp_ns, generation, event_type)
    first_ts = None
    last_ts = None

    DOTNET_PROVIDER = "Microsoft-Windows-DotNETRuntime"
    DOTNET_RUNDOWN_PROVIDER = "Microsoft-Windows-DotNETRuntimeRundown"

    # The EventPipe stream is a series of blocks
    # Each block starts with: type_code (varint), block_size (uint32), block_data
    # type_code: 1=MetadataBlock, 2=EventBlock, 3=StackBlock, 4=SequencePointBlock

    BLOCK_METADATA = 1
    BLOCK_EVENT = 2
    BLOCK_STACK = 3
    BLOCK_SEQUENCE = 4

    while pos < len(data) - 8:
        # Read block type
        try:
            block_type, pos = read_varint(data, pos)
        except Exception:
            break

        if block_type == 0:
            break

        # Block size (bytes following)
        if pos + 4 > len(data):
            break
        block_size = struct.unpack_from('<I', data, pos)[0]; pos += 4

        block_start = pos
        block_end = min(pos + block_size, len(data))

        if block_type == BLOCK_METADATA:
            # MetadataBlock: series of metadata events
            # Each metadata event: metadataId (uint16), providerName (string16), eventId (uint32),
            #   eventName (string16), keywords (uint64), version (uint32), level (uint32),
            #   fieldCount (uint32), fields (fieldName, typeCode pairs)
            mpos = block_start
            while mpos < block_end - 4:
                try:
                    meta_id = struct.unpack_from('<H', data, mpos)[0]; mpos += 2
                    provider_name, mpos = read_string(data, mpos)
                    event_id = struct.unpack_from('<I', data, mpos)[0]; mpos += 4
                    event_name, mpos = read_string(data, mpos)
                    keywords = struct.unpack_from('<Q', data, mpos)[0]; mpos += 8
                    version = struct.unpack_from('<I', data, mpos)[0]; mpos += 4
                    level = struct.unpack_from('<I', data, mpos)[0]; mpos += 4
                    field_count = struct.unpack_from('<I', data, mpos)[0]; mpos += 4
                    fields = []
                    for _ in range(field_count):
                        fname, mpos = read_string(data, mpos)
                        ftype = struct.unpack_from('<I', data, mpos)[0]; mpos += 4
                        fields.append((fname, ftype))
                    metadata[meta_id] = (provider_name, event_id, event_name, fields)
                except Exception:
                    break

        elif block_type == BLOCK_EVENT:
            # EventBlock: series of events
            # Each event: size (uint32), metadataId (uint16), sequenceNumber (uint32),
            #   captureThreadId (uint64), processId (uint32), stackId (uint32),
            #   timestamp (uint64), activityId (128 bits), relatedActivityId (128 bits),
            #   payloadSize (uint32), payload (bytes)
            epos = block_start
            while epos < block_end - 4:
                try:
                    evt_size = struct.unpack_from('<I', data, epos)[0]; epos += 4
                    evt_end = epos + evt_size - 4
                    if evt_end > block_end:
                        break

                    meta_id = struct.unpack_from('<H', data, epos)[0]; epos += 2
                    seq_num = struct.unpack_from('<I', data, epos)[0]; epos += 4
                    capture_tid = struct.unpack_from('<Q', data, epos)[0]; epos += 8
                    proc_id = struct.unpack_from('<I', data, epos)[0]; epos += 4
                    stack_id = struct.unpack_from('<I', data, epos)[0]; epos += 4
                    timestamp = struct.unpack_from('<Q', data, epos)[0]; epos += 8
                    # skip activity IDs (2 * 16 bytes)
                    epos += 32
                    payload_size = struct.unpack_from('<I', data, epos)[0]; epos += 4
                    payload = data[epos:epos + payload_size]; epos += payload_size

                    # Align to evt_end
                    epos = max(epos, evt_end)

                    if first_ts is None:
                        first_ts = timestamp
                    last_ts = timestamp

                    if meta_id in metadata:
                        provider, event_id, event_name, fields = metadata[meta_id]
                        if provider == DOTNET_PROVIDER and event_id == GC_START_ID and len(payload) >= 12:
                            # GCStart: Count(uint32), Depth(uint32)=generation, Reason(uint32), Type(uint32), ClrInstanceID(uint16)
                            count = struct.unpack_from('<I', payload, 0)[0]
                            generation = struct.unpack_from('<I', payload, 4)[0]
                            reason = struct.unpack_from('<I', payload, 8)[0]
                            gc_events.append((timestamp, generation, 'GCStart'))

                except Exception:
                    break

        pos = max(pos, block_end)

    return {
        'gc_events': gc_events,
        'metadata': metadata,
        'first_ts': first_ts,
        'last_ts': last_ts,
    }

def summarize(result):
    if result is None:
        return
    events = result['gc_events']
    gen_counts = [0, 0, 0]
    for ts, gen, etype in events:
        if 0 <= gen <= 2:
            gen_counts[gen] += 1
    total = sum(gen_counts)
    first_ts = result['first_ts']
    last_ts = result['last_ts']
    dur_s = (last_ts - first_ts) / 1e7 if (first_ts and last_ts) else 0  # 100ns ticks to seconds

    print(f"gen0_gc_count={gen_counts[0]}")
    print(f"gen1_gc_count={gen_counts[1]}")
    print(f"gen2_gc_count={gen_counts[2]}")
    print(f"total_gc_count={total}")
    print(f"trace_duration_s={dur_s:.1f}")
    if dur_s > 0 and total > 0:
        print(f"gc_rate_per_s={total/dur_s:.2f}")
    return gen_counts, total

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <file.nettrace>", file=sys.stderr)
        sys.exit(1)
    path = sys.argv[1]
    if not os.path.exists(path):
        print(f"ERROR: file not found: {path}", file=sys.stderr)
        sys.exit(1)
    result = parse_nettrace(path)
    summarize(result)
