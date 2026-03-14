// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdJson} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {IJBBuybackHook} from "../../src/interfaces/IJBBuybackHook.sol";
import {IJBBuybackHookRegistry} from "../../src/interfaces/IJBBuybackHookRegistry.sol";

import {SphinxConstants, NetworkInfo} from "@sphinx-labs/contracts/contracts/foundry/SphinxConstants.sol";

struct BuybackDeployment {
    IJBBuybackHook hook;
    IJBBuybackHookRegistry registry;
}

library BuybackDeploymentLib {
    // Cheat code address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant VM = Vm(VM_ADDRESS);

    function getDeployment(string memory path) internal returns (BuybackDeployment memory deployment) {
        // get chainId for which we need to get the deployment.
        uint256 chainId = block.chainid;

        // Deploy to get the constants.
        // TODO: get constants without deploy.
        SphinxConstants sphinxConstants = new SphinxConstants();
        NetworkInfo[] memory networks = sphinxConstants.getNetworkInfoArray();

        for (uint256 _i; _i < networks.length; _i++) {
            if (networks[_i].chainId == chainId) {
                return getDeployment({path: path, networkName: networks[_i].name});
            }
        }

        revert("ChainID is not (currently) supported by Sphinx.");
    }

    function getDeployment(
        string memory path,
        string memory networkName
    )
        internal
        view
        returns (BuybackDeployment memory deployment)
    {
        deployment.hook = IJBBuybackHook(
            _getDeploymentAddress({
                path: path, projectName: "nana-buyback-hook-v6", networkName: networkName, contractName: "JBBuybackHook"
            })
        );

        deployment.registry = IJBBuybackHookRegistry(
            _getDeploymentAddress({
                path: path,
                projectName: "nana-buyback-hook-v6",
                networkName: networkName,
                contractName: "JBBuybackHookRegistry"
            })
        );
    }

    /// @notice Get the address of a contract that was deployed by the Deploy script.
    /// @dev Reverts if the contract was not found.
    /// @param path The path to the deployment file.
    /// @param contractName The name of the contract to get the address of.
    /// @return The address of the contract.
    function _getDeploymentAddress(
        string memory path,
        string memory projectName,
        string memory networkName,
        string memory contractName
    )
        internal
        view
        returns (address)
    {
        string memory deploymentJson =
        // forge-lint: disable-next-line(unsafe-cheatcode)
        VM.readFile(string.concat(path, projectName, "/", networkName, "/", contractName, ".json"));
        return stdJson.readAddress({json: deploymentJson, key: ".address"});
    }
}
