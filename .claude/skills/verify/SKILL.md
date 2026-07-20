# Verify Folio Contract Changes

Use an isolated Anvil chain and drive changed Folio behavior through public transactions.

1. Install dependencies and compile: `pnpm install --frozen-lockfile && forge build`.
2. Start Anvil with the repository's runtime limits:
   `anvil --port <unused-port> --silent --disable-code-size-limit --gas-limit 18446744073709551615`.
3. Deploy a minimal Folio fixture with a temporary Forge script. Broadcast sequentially with:
   `forge script <script>:<contract> --broadcast --slow --gas-estimate-multiplier 200 --rpc-url http://127.0.0.1:<port>`.
4. Drive the public ABI with `cast send` for successful state changes and `cast call --from <authorized-account>` for expected custom-error probes. Use `anvil_setNextBlockTimestamp` plus `evm_mine` for timestamp boundaries.
5. Regenerate and inspect the consumer ABI with `pnpm export`; confirm the affected function inputs, errors, and selector through `artifacts/Folio.ts`.
6. Remove temporary scripts, broadcast/cache output, and generated artifacts before finalizing unless they are part of the requested change.

Gotchas:

- Plain Anvil defaults can fail while deploying `FolioDeployer`; use both the code-size override and large gas limit above.
- Broadcast deployment should use `--slow` and a larger gas-estimate multiplier.
- The repository's configured Solidity formatter is Prettier (`pnpm format:check`), not the local `forge fmt` output.
