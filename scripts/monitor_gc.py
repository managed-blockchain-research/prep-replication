#!/usr/bin/env python3
"""
GC Log Monitor and Analyzer for E-Spill Baseline Testing

Parses G1 GC logs and extracts key metrics for baseline analysis:
- GC frequency and types (Young, Mixed, Full)
- Pause times (min/max/mean/percentiles)
- GC overhead ratio (critical for determining e-spill threshold)
- Memory usage patterns over time
"""

import re
import sys
import statistics
from datetime import datetime
from collections import defaultdict
from pathlib import Path

class GCLogAnalyzer:
    def __init__(self, log_file):
        self.log_file = log_file
        self.gc_events = []
        self.pause_times = []
        self.gc_types = defaultdict(int)
        self.total_runtime = 0
        self.total_gc_time = 0
        
    def parse_log(self):
        """Parse G1 GC log file and extract metrics"""
        with open(self.log_file, 'r') as f:
            for line in f:
                self._parse_line(line)
        
        if self.gc_events:
            # Calculate total runtime from first to last GC event
            first_event_time = self.gc_events[0]['timestamp']
            last_event_time = self.gc_events[-1]['timestamp']
            self.total_runtime = last_event_time - first_event_time
            
    def _parse_line(self, line):
        """Parse individual log line"""
        # Parse timestamp - handle both formats:
        # [XXXs] or [2026-01-27T11:25:20.962+0900]
        timestamp_match = re.search(r'\[(\d+\.\d+)s\]', line)
        if timestamp_match:
            timestamp = float(timestamp_match.group(1))
        else:
            # Try ISO timestamp format
            iso_match = re.search(r'\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+)', line)
            if not iso_match:
                return
            # Convert to seconds from start (use first timestamp as baseline)
            if not hasattr(self, '_start_timestamp'):
                from datetime import datetime
                dt_str = iso_match.group(1)
                self._start_timestamp = datetime.strptime(dt_str[:23], '%Y-%m-%dT%H:%M:%S.%f')
                timestamp = 0.0
            else:
                from datetime import datetime
                dt_str = iso_match.group(1)
                dt = datetime.strptime(dt_str[:23], '%Y-%m-%dT%H:%M:%S.%f')
                timestamp = (dt - self._start_timestamp).total_seconds()
        
        # Parse GC pause events
        # Example: GC(0) Pause Young (Concurrent Start) (Metadata GC Threshold) 240M->21M(92160M) 11.688ms
        pause_match = re.search(r'GC\((\d+)\)\s+Pause\s+(\w+.*?)\s+\d+M->\d+M\(\d+M\)\s+([\d.]+)ms', line)
        if pause_match:
            gc_id = int(pause_match.group(1))
            gc_type = pause_match.group(2).strip()
            pause_ms = float(pause_match.group(3))
            
            self.gc_events.append({
                'id': gc_id,
                'timestamp': timestamp,
                'type': gc_type,
                'pause_ms': pause_ms
            })
            
            self.pause_times.append(pause_ms)
            self.gc_types[gc_type] += 1
            self.total_gc_time += pause_ms / 1000.0  # Convert to seconds
            
    def calculate_metrics(self):
        """Calculate key GC metrics"""
        if not self.pause_times:
            return {
                'error': 'No GC events found in log file'
            }
            
        metrics = {
            'total_gc_events': len(self.gc_events),
            'gc_types': dict(self.gc_types),
            'total_runtime_sec': self.total_runtime,
            'total_gc_time_sec': self.total_gc_time,
            'gc_overhead_ratio': (self.total_gc_time / self.total_runtime * 100) if self.total_runtime > 0 else 0,
            'pause_times_ms': {
                'min': min(self.pause_times),
                'max': max(self.pause_times),
                'mean': statistics.mean(self.pause_times),
                'median': statistics.median(self.pause_times),
                'stdev': statistics.stdev(self.pause_times) if len(self.pause_times) > 1 else 0,
            },
            'gc_frequency_per_sec': len(self.gc_events) / self.total_runtime if self.total_runtime > 0 else 0
        }
        
        # Calculate percentiles
        sorted_pauses = sorted(self.pause_times)
        metrics['pause_times_ms']['p50'] = self._percentile(sorted_pauses, 50)
        metrics['pause_times_ms']['p95'] = self._percentile(sorted_pauses, 95)
        metrics['pause_times_ms']['p99'] = self._percentile(sorted_pauses, 99)
        
        return metrics
        
    def _percentile(self, sorted_data, percentile):
        """Calculate percentile from sorted data"""
        if not sorted_data:
            return 0
        index = int(len(sorted_data) * percentile / 100.0)
        if index >= len(sorted_data):
            index = len(sorted_data) - 1
        return sorted_data[index]
        
    def print_summary(self, metrics):
        """Print formatted summary"""
        if 'error' in metrics:
            print(f"ERROR: {metrics['error']}")
            return
            
        print("=" * 70)
        print("GC LOG ANALYSIS SUMMARY")
        print("=" * 70)
        print(f"Log File: {self.log_file}")
        print()
        
        print("OVERALL METRICS")
        print("-" * 70)
        print(f"Total Runtime:        {metrics['total_runtime_sec']:.2f} seconds")
        print(f"Total GC Events:      {metrics['total_gc_events']}")
        print(f"Total GC Time:        {metrics['total_gc_time_sec']:.3f} seconds")
        print(f"GC Overhead Ratio:    {metrics['gc_overhead_ratio']:.2f}% ⚠️  (E-SPILL THRESHOLD)")
        print(f"GC Frequency:         {metrics['gc_frequency_per_sec']:.3f} GCs/second")
        print()
        
        print("GC TYPES")
        print("-" * 70)
        for gc_type, count in sorted(metrics['gc_types'].items(), key=lambda x: x[1], reverse=True):
            print(f"  {gc_type:40s}: {count:5d}")
        print()
        
        print("PAUSE TIME STATISTICS (milliseconds)")
        print("-" * 70)
        pt = metrics['pause_times_ms']
        print(f"  Min:     {pt['min']:8.2f} ms")
        print(f"  Mean:    {pt['mean']:8.2f} ms")
        print(f"  Median:  {pt['median']:8.2f} ms")
        print(f"  P95:     {pt['p95']:8.2f} ms")
        print(f"  P99:     {pt['p99']:8.2f} ms")
        print(f"  Max:     {pt['max']:8.2f} ms")
        print(f"  StdDev:  {pt['stdev']:8.2f} ms")
        print()
        
        # E-spill threshold analysis
        print("E-SPILL THRESHOLD ANALYSIS")
        print("-" * 70)
        optimal_threshold = 10.0  # From the paper
        current_overhead = metrics['gc_overhead_ratio']
        
        if current_overhead < optimal_threshold:
            print(f"✓ Current GC overhead ({current_overhead:.2f}%) is below optimal")
            print(f"  threshold ({optimal_threshold}%).")
            print(f"  This workload has LOW memory pressure - increase load for baseline.")
        else:
            print(f"⚠️  Current GC overhead ({current_overhead:.2f}%) EXCEEDS optimal")
            print(f"  threshold ({optimal_threshold}%).")
            print(f"  E-spill would be triggered to reduce GC pressure!")
        print()
        
    def export_csv(self, output_file):
        """Export detailed GC events to CSV"""
        with open(output_file, 'w') as f:
            f.write("gc_id,timestamp_sec,gc_type,pause_ms\n")
            for event in self.gc_events:
                f.write(f"{event['id']},{event['timestamp']},{event['type']},{event['pause_ms']}\n")
        print(f"Detailed GC events exported to: {output_file}")

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 monitor_gc.py <gc_log_file> [output_csv]")
        print()
        print("Example:")
        print("  python3 monitor_gc.py baseline_gc_20260127_110907.log")
        print("  python3 monitor_gc.py baseline_gc.log results/low_intensity/gc_events.csv")
        sys.exit(1)
        
    log_file = sys.argv[1]
    if not Path(log_file).exists():
        print(f"ERROR: Log file not found: {log_file}")
        sys.exit(1)
        
    analyzer = GCLogAnalyzer(log_file)
    analyzer.parse_log()
    metrics = analyzer.calculate_metrics()
    analyzer.print_summary(metrics)
    
    # Export CSV if requested
    if len(sys.argv) >= 3:
        output_csv = sys.argv[2]
        analyzer.export_csv(output_csv)
        print()

if __name__ == '__main__':
    main()
