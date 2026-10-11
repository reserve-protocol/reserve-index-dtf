/*
 * Common methods and summaries for Folio verification
 */
using FolioHarness as FolioHarness;

methods {
    
    // TrustedFiller methods  
    function _.initialize(address,address,address,uint256,uint256) external => DISPATCHER(true);
    function _.bidCallback(address,uint256,bytes) external => DISPATCHER(true);
    function _.createTrustedFiller(address,address,bytes32) external => DISPATCHER(true);
    
    // FolioHarness-specific getters
    function totalSupply() external returns (uint256);
    function totalAssets() external returns (address[], uint256[]) envfree;
    function nextAuctionId() external returns (uint256) envfree;
    function lastPoke() external returns (uint256) envfree;
    function getBalanceOfToken(address) external returns (uint256) envfree;
    
    // Standard Folio getters
    function getAuctionPrice(uint256, address) external returns (IFolio.PriceRange) envfree;
    function getBid(uint256, address, address, uint256) external returns (uint256, uint256, uint256);
}