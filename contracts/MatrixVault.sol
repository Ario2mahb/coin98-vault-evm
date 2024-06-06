// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "./Coin98VaultV2.sol";
import "./lib/Token.sol";
import "./lib/VRC725.sol";

contract MatrixVault is Coin98VaultV2 {
    using AdvancedERC20 for IERC20;

    // NFT ID => (Event ID => Claimed)
    mapping(uint256 => mapping(uint256 => bool)) internal _isClaimed;

    event RedeemedForHolder(
        uint256 indexed eventId,
        address receiver,
        address collectionAddress,
        uint256 index,
        uint256 timestamp,
        uint256 tokenId,
        uint256 receivingAmount
    );

    function _setTokenClaimed(uint256 tokenId, uint256 eventId) internal {
        _isClaimed[tokenId][eventId] = true;
    }

    function redeemForCollectionHolder(
        uint256 eventId,
        address receiver,
        uint256 index,
        uint256 timestamp,
        address collectionAddress,
        uint256 tokenId,
        uint256 receivingAmount,
        uint256 sendingAmount,
        bool forAllHolder,
        bytes32[] calldata proofs
    ) public payable {
        uint256 fee = IVaultConfig(_factory).fee();
        uint256 gasLimit = IVaultConfig(_factory).gasLimit();
        if (fee > 0) {
            require(_msgValue() == fee, "C98Vault: Invalid fee");
        }
        require(collectionAddress != address(0), "C98Vault: Invalid collection");
        require(receiver != address(0), "C98Vault: Invalid receiver");
        require(VRC725(collectionAddress).balanceOf(receiver) > 0, "C98Vault: Receiver has no NFT");
        require(VRC725(collectionAddress).ownerOf(tokenId) == receiver, "C98Vault: Invalid owner");
        require(timestamp <= block.timestamp, "C98Vault: Schedule locked");
        require(!_isClaimed[tokenId][eventId], "C98Vault: Claimed");
        require(!isRedeemed(eventId, index), "C98Vault: Redeemed");

        EventData storage eventData = _eventDatas[eventId];
        require(eventData.isActive > 0, "C98Vault: Invalid event");

        if (forAllHolder) {
            uint256 zero = 0;
            bytes32 node = keccak256(
                abi.encodePacked(index, timestamp, collectionAddress, zero, receivingAmount, sendingAmount)
            );
            require(MerkleProof.verify(proofs, eventData.merkleRoot, node), "C98Vault: Invalid proof");
        } else {
            bytes32 node = keccak256(
                abi.encodePacked(index, timestamp, collectionAddress, tokenId, receivingAmount, sendingAmount)
            );
            require(MerkleProof.verify(proofs, eventData.merkleRoot, node), "C98Vault: Invalid proof");
        }

        {
            uint256 availableAmount;
            if (eventData.receivingToken == address(0)) {
                availableAmount = address(this).balance;
            } else {
                availableAmount = IERC20(eventData.receivingToken).balanceOf(address(this));
            }

            require(receivingAmount <= availableAmount, "C98Vault: Insufficient token");
        }

        _setRedemption(eventId, index);
        _setTokenClaimed(tokenId, eventId);

        if (fee > 0) {
            uint256 reward = IVaultConfig(_factory).ownerReward();
            uint256 finalFee = fee - reward;
            (bool success, ) = _factory.call{value: finalFee, gas: gasLimit}("");
            require(success, "C98Vault: Unable to charge fee");
        }
        if (sendingAmount > 0) {
            IERC20(eventData.sendingToken).safeTransferFrom(_msgSender(), address(this), sendingAmount);
        }
        if (eventData.receivingToken == address(0)) {
            (bool success, ) = receiver.call{value: receivingAmount, gas: gasLimit}("");
            require(success, "C98Vault: Send ETH failed");
        } else {
            IERC20(eventData.receivingToken).safeTransfer(receiver, receivingAmount);
        }

        emit RedeemedForHolder(eventId, receiver, collectionAddress, index, timestamp, tokenId, receivingAmount);
    }
}
