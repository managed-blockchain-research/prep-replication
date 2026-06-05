// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract StateBloater {
    mapping(uint256 => uint256) public heavyStorage;

    event Bloated(uint256 startIdx, uint256 count);

    function bloat(uint256 startIdx, uint256 count) external {
        uint256 end = startIdx + count;
        for (uint256 i = startIdx; i < end; i++) {
            heavyStorage[i] = i;
        }
        emit Bloated(startIdx, count);
    }

    // Accepts large calldata — forces NM to allocate a large managed byte[] in the .NET LOH
    // (any tx with data >85 KB goes to Large Object Heap, triggering Gen2 STW collections)
    function sink(bytes calldata) external {}
}
