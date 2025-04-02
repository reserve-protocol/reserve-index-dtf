// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

uint256 constant MAX_TVL_FEE = 0.1e18; // D18{1/year} 10% annually
uint256 constant MAX_MINT_FEE = 0.05e18; // D18{1} 5%
uint256 constant MIN_AUCTION_LENGTH = 60; // {s} 1 min
uint256 constant MAX_AUCTION_LENGTH = 604800; // {s} 1 week
uint256 constant MAX_AUCTION_DELAY = 604800; // {s} 1 week
uint256 constant MAX_FEE_RECIPIENTS = 64;
uint256 constant MAX_TTL = 604800 * 4; // {s} 4 weeks
uint256 constant MAX_RATE = 1e54; // D18{buyTok/sellTok}
uint256 constant MAX_PRICE_RANGE = 1e9; // {1}
uint256 constant RESTRICTED_AUCTION_BUFFER = 120; // {s} 2 min

uint256 constant ONE_OVER_YEAR = 31709791983; // D18{1/s} 1e18 / 31536000
uint256 constant ONE_DAY = 24 hours; // {s} 1 day

uint256 constant D18 = 1e18; // D18
uint256 constant D27 = 1e27; // D27
