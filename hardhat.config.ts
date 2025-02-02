// import "@nomicfoundation/hardhat-toolbox";
// import "@nomicfoundation/hardhat-chai-matchers";
// import "@nomiclabs/hardhat-ethers";
// import "@openzeppelin/hardhat-upgrades"
import "@nomiclabs/hardhat-ethers";
import "hardhat-preprocessor";
import "@typechain/hardhat";
import "@nomicfoundation/hardhat-foundry";
import * as fs from "fs";

function getRemappings() {
  return fs
    .readFileSync("remappings.txt", "utf8")
    .split("\n")
    .filter(Boolean) // remove empty lines
    .map((line) => line.trim().split("="));
}

import { HardhatUserConfig } from "hardhat/types";
const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      gas: 0x1ffffffff,
      blockGasLimit: 0x1fffffffffffff,
      allowUnlimitedContractSize: true,
    },
    localhost: {
      // network for long-lived mainnet forks
      chainId: 31337,
      url: "http://127.0.0.1:8546",
      gas: 0x1ffffffff,
      blockGasLimit: 0x1fffffffffffff,
      allowUnlimitedContractSize: true,
      timeout: 0,
    },
  },
  solidity: {
    compilers: [
      {
        version: "0.8.28",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
    ],
  },
  preprocess: {
    eachLine: (hre) => ({
      transform: (line: string) => {
        if (line.match(/^\s*import /i)) {
          getRemappings().forEach(([find, replace]) => {
            // console.log(find, replace);
            if (line.match(find)) {
              line = line.replace(find, replace);
            }
          });
        }
        return line;
      },
    }),
  },
};

export default config;
