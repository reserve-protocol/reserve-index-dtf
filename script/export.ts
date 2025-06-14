import fs from "node:fs/promises";
import path from "node:path";

const convertToTypescript = (name: string, object: Object) => {
  return `export const ${name}Artifact = ${JSON.stringify(object)} as const;`;
};

const artifactsList = [
  "Folio.sol/Folio.json",
  "FolioLens.sol/FolioLens.json",
  "GovernanceDeployer.sol/GovernanceDeployer.json",
  "FolioDeployer.sol/FolioDeployer.json",
  "FolioProxy.sol/FolioProxyAdmin.json",
  "FolioProxy.sol/FolioProxy.json",
  "StakingVault.sol/StakingVault.json",
  "UnstakingManager.sol/UnstakingManager.json",
];

const artifactDirectory = "artifacts";

async function main() {
  await fs.rm(artifactDirectory, { recursive: true }).catch(() => {});
  await fs.mkdir(artifactDirectory, { recursive: true });

  for (const artifact of artifactsList) {
    const artifactPath = path.join("../out", artifact);
    const artifactObject = require(artifactPath);
    const artifactName = artifact.split("/")[1].split(".")[0];

    await fs.writeFile(
      path.join(artifactDirectory, `${artifactName}.ts`),
      convertToTypescript(artifactName, {
        contractName: artifactName,
        abi: artifactObject.abi,
      }),
    );

    console.log("Artifact Exported:", artifact);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
