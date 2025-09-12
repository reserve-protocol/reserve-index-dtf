// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

uint256 constant AUCTION_WARMUP = 30; // {s} 30 seconds
uint256 constant MAX_TVL_FEE = 0.1e18; // D18{1/year} 10% annually
uint256 constant MAX_MINT_FEE = 0.05e18; // D18{1} 5%
uint256 constant MIN_MINT_FEE = 0.0003e18; // D18{1} 0.03%
uint256 constant MIN_AUCTION_LENGTH = 60; // {s} 1 min
uint256 constant MAX_AUCTION_LENGTH = 604800; // {s} 1 week
uint256 constant MAX_FEE_RECIPIENTS = 64;
uint256 constant MAX_TTL = 604800 * 4; // {s} 4 weeks
uint256 constant MAX_LIMIT = 1e27; // D18{BU/share}
uint256 constant MAX_WEIGHT = 1e54; // D27{tok/BU}
uint256 constant MAX_TOKEN_BUY_AMOUNT = 1e36; // {tok}
uint256 constant MAX_TOKEN_PRICE = 1e45; // D27{UoA/tok}
uint256 constant MAX_TOKEN_PRICE_RANGE = 1e2; // {1}
uint256 constant RESTRICTED_AUCTION_BUFFER = 120; // {s} 2 min

uint256 constant ONE_OVER_YEAR = 31709791983; // D18{1/s} 1e18 / 31536000

uint256 constant ONE_DAY = 24 hours; // {s} 1 day

uint256 constant D18 = 1e18; // D18
uint256 constant D27 = 1e27; // D27

bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
bytes32 constant AUCTION_APPROVER = keccak256("AUCTION_APPROVER"); // 0x2be23b023f3eee571adc019cdcf3f0bcf041151e6ff405a4bf0c4bfc6faea8c9 DEPRECATED
bytes32 constant REBALANCE_MANAGER = keccak256("REBALANCE_MANAGER"); // 0x4ff6ae4d6a29e79ca45c6441bdc89b93878ac6118485b33c8baa3749fc3cb130
bytes32 constant AUCTION_LAUNCHER = keccak256("AUCTION_LAUNCHER"); // 0x13ff1b2625181b311f257c723b5e6d366eb318b212d9dd694c48fcf227659df5
bytes32 constant BRAND_MANAGER = keccak256("BRAND_MANAGER"); // 0x2d8e650da9bd8c373ab2450d770f2ed39549bfc28d3630025cecc51511bcd374

// keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20")) - 1)) & ~bytes32(uint256(0xff))
bytes32 constant ERC20_STORAGE_LOCATION = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;
