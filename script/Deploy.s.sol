// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CoreDeployment, CoreDeploymentLib} from "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import {Univ4RouterDeployment, Univ4RouterDeploymentLib} from
    "@bananapus/univ4-router-v6/script/helpers/Univ4RouterDeploymentLib.sol";

import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {JBBuybackHookRegistry} from "src/JBBuybackHookRegistry.sol";

contract DeployScript is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    /// @notice tracks the deployment of the univ4-router contracts for the chain we are deploying to.
    Univ4RouterDeployment router;

    /// @notice the salts that are used to deploy the contracts.
    bytes32 buybackHook = "JBBuybackHookV6";

    /// @notice tracks the addresses that are required for the chain we are deploying to.
    address poolManager;
    address trustedForwarder;

    function configureSphinx() public override {
        sphinxConfig.projectName = "nana-buyback-hook-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    function run() public {
        // Get the deployment addresses for the nana CORE for this chain.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v6/deployments/"))
        );

        // Get the deployment addresses for the univ4-router for this chain.
        router = Univ4RouterDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v6/deployments/"))
        );

        trustedForwarder = core.permissions.trustedForwarder();

        // Uniswap V4 PoolManager addresses per chain.
        if (block.chainid == 1) {
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90; // Ethereum Mainnet
        } else if (block.chainid == 11_155_111) {
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90; // Ethereum Sepolia
        } else if (block.chainid == 10) {
            poolManager = 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3; // Optimism Mainnet
        } else if (block.chainid == 8453) {
            poolManager = 0x498581fF718922c3f8e6A244956aF099B2652b2b; // Base Mainnet
        } else if (block.chainid == 11_155_420) {
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90; // Optimism Sepolia
        } else if (block.chainid == 84_532) {
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90; // Base Sepolia
        } else if (block.chainid == 42_161) {
            poolManager = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32; // Arbitrum Mainnet
        } else if (block.chainid == 421_614) {
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90; // Arbitrum Sepolia
        } else {
            revert("Invalid RPC / no juice contracts deployed on this network");
        }

        // Perform the deployment transactions.
        deploy();
    }

    function deploy() public sphinx {
        // Deploy the registry.
        JBBuybackHookRegistry registry = new JBBuybackHookRegistry{salt: buybackHook}(
            core.permissions, core.projects, safeAddress(), trustedForwarder
        );

        // Deploy the V4 buyback hook.
        JBBuybackHook hook = new JBBuybackHook{salt: buybackHook}(
            core.directory,
            core.permissions,
            core.prices,
            core.projects,
            core.tokens,
            IPoolManager(poolManager),
            router.hook,
            trustedForwarder
        );

        // Configure the hook to be the default.
        registry.setDefaultHook(hook);
    }

    function _isDeployed(bytes32 salt, bytes memory creationCode, bytes memory arguments) internal view returns (bool) {
        address _deployedTo = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });

        return address(_deployedTo).code.length != 0;
    }
}
