// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";

import {Sphinx} from "@sphinx-labs/contracts/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {JBBuybackHook} from "src/JBBuybackHook.sol";
import {JBBuybackHookRegistry} from "src/JBBuybackHookRegistry.sol";
import {IWETH9} from "src/interfaces/external/IWETH9.sol";

contract DeployScript is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    /// @notice the salts that are used to deploy the contracts.
    bytes32 BUYBACK_HOOK = "JBBuybackHook";

    /// @notice tracks the addresses that are required for the chain we are deploying to.
    address weth;
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

        trustedForwarder = core.permissions.trustedForwarder();

        // Uniswap V4 PoolManager addresses per chain.
        // Ethereum Mainnet
        if (block.chainid == 1) {
            weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
            // Ethereum Sepolia
        } else if (block.chainid == 11_155_111) {
            weth = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
            // Optimism Mainnet
        } else if (block.chainid == 10) {
            weth = 0x4200000000000000000000000000000000000006;
            poolManager = 0x9a13f98cb987694c9f086b1f5eb990eea8264ec3;
            // Base Mainnet
        } else if (block.chainid == 8453) {
            weth = 0x4200000000000000000000000000000000000006;
            poolManager = 0x498581ff718922c3f8e6a244956af099b2652b2b;
            // Optimism Sepolia
        } else if (block.chainid == 11_155_420) {
            weth = 0x4200000000000000000000000000000000000006;
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
            // BASE Sepolia
        } else if (block.chainid == 84_532) {
            weth = 0x4200000000000000000000000000000000000006;
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
            // Arbitrum Mainnet
        } else if (block.chainid == 42_161) {
            weth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
            poolManager = 0x360e68faccca8ca495c1b759fd9eee466db9fb32;
            // Arbitrum Sepolia
        } else if (block.chainid == 421_614) {
            weth = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
            poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
        } else {
            revert("Invalid RPC / no juice contracts deployed on this network");
        }

        // Perform the deployment transactions.
        deploy();
    }

    function deploy() public sphinx {
        // Deploy the registry.
        JBBuybackHookRegistry registry = new JBBuybackHookRegistry{salt: BUYBACK_HOOK}(
            core.permissions, core.projects, safeAddress(), trustedForwarder
        );

        // Deploy the V4 buyback hook.
        JBBuybackHook hook = new JBBuybackHook{salt: BUYBACK_HOOK}(
            core.directory,
            core.permissions,
            core.prices,
            core.projects,
            core.tokens,
            IWETH9(weth),
            IPoolManager(poolManager),
            trustedForwarder
        );

        // Configure the hook to be the default.
        registry.setDefaultHook(hook);
    }

    function _isDeployed(
        bytes32 salt,
        bytes memory creationCode,
        bytes memory arguments
    )
        internal
        view
        returns (bool)
    {
        address _deployedTo = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });

        return address(_deployedTo).code.length != 0;
    }
}
