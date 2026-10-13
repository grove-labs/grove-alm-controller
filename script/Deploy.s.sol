// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { ScriptTools } from "dss-test/ScriptTools.sol";

import "forge-std/Script.sol";

import { ControllerInstance } from "../deploy/ControllerInstance.sol";

import { ForeignControllerDeploy, MainnetControllerDeploy } from "../deploy/ControllerDeploy.sol";

import { MidnightMakerDeploy } from "../deploy/MidnightMakerDeploy.sol";

import { MidnightRatifier }     from "../src/MidnightRatifier.sol";
import { ProxyFundingStrategy } from "../src/ProxyFundingStrategy.sol";

contract DeployMainnetFull is Script {

    using stdJson     for string;
    using ScriptTools for string;

    function run() external {
        vm.setEnv("FOUNDRY_ROOT_CHAINID",             "1");
        vm.setEnv("FOUNDRY_EXPORTS_OVERWRITE_LATEST", "true");

        vm.createSelectFork(getChain("mainnet").rpcUrl);

        console.log("Deploying Mainnet ALMProxy, Controller and RateLimits...");

        string memory fileSlug = string(abi.encodePacked("mainnet-", vm.envString("ENV")));

        vm.startBroadcast();

        string memory config = ScriptTools.loadConfig(fileSlug);

        ControllerInstance memory instance = MainnetControllerDeploy.deployFull({
            admin                    : config.readAddress(".admin"),
            vault                    : config.readAddress(".allocatorVault"),
            psm                      : config.readAddress(".psm"),
            daiUsds                  : config.readAddress(".daiUsds"),
            cctp                     : config.readAddress(".cctpTokenMessenger"),
            uniswapV3Router          : config.readAddress(".uniswapV3Router"),
            uniswapV3PositionManager : config.readAddress(".uniswapV3PositionManager")
        });

        vm.stopBroadcast();

        console.log("ALMProxy   deployed at", instance.almProxy);
        console.log("Controller deployed at", instance.controller);
        console.log("RateLimits deployed at", instance.rateLimits);

        ScriptTools.exportContract(fileSlug, "almProxy",   instance.almProxy);
        ScriptTools.exportContract(fileSlug, "controller", instance.controller);
        ScriptTools.exportContract(fileSlug, "rateLimits", instance.rateLimits);
    }

}

contract DeployMainnetController is Script {

    using stdJson     for string;
    using ScriptTools for string;

    function run() external {
        vm.setEnv("FOUNDRY_ROOT_CHAINID",             "1");
        vm.setEnv("FOUNDRY_EXPORTS_OVERWRITE_LATEST", "true");

        vm.createSelectFork(getChain("mainnet").rpcUrl);

        console.log("Deploying Mainnet Controller...");

        string memory fileSlug = string(abi.encodePacked("mainnet-", vm.envString("ENV")));

        vm.startBroadcast();

        string memory config = ScriptTools.loadConfig(fileSlug);

        address controller = MainnetControllerDeploy.deployController({
            admin                    : config.readAddress(".admin"),
            almProxy                 : config.readAddress(".almProxy"),
            rateLimits               : config.readAddress(".rateLimits"),
            vault                    : config.readAddress(".allocatorVault"),
            psm                      : config.readAddress(".psm"),
            daiUsds                  : config.readAddress(".daiUsds"),
            cctp                     : config.readAddress(".cctpTokenMessenger"),
            uniswapV3Router          : config.readAddress(".uniswapV3Router"),
            uniswapV3PositionManager : config.readAddress(".uniswapV3PositionManager")
        });

        vm.stopBroadcast();

        console.log("Controller deployed at", controller);

        ScriptTools.exportContract(fileSlug, "controller", controller);
    }

}

contract ForeignScript is Script {

    function setUpNonStandardChains() internal {
        setChain("monad", ChainData({
            name    : "Monad",
            rpcUrl  : vm.envString("MONAD_RPC_URL"),
            chainId : 143
        }));

        setChain("plume", ChainData({
            name    : "Plume",
            rpcUrl  : vm.envString("PLUME_RPC_URL"),
            chainId : 98866
        }));

        setChain("plasma", ChainData({
            name    : "Plasma",
            rpcUrl  : vm.envString("PLASMA_RPC_URL"),
            chainId : 9745
        }));

        string memory customChain     = vm.envOr("CHAIN",             string(""));
        string memory customName      = vm.envOr("CUSTOM_CHAIN_NAME", string(""));
        string memory customRpcUrl    = vm.envOr("CUSTOM_RPC_URL",    string(""));
        uint256       customChainId   = vm.envOr("CUSTOM_CHAIN_ID",   uint256(0));
        if (
            bytes(customChain).length    != 0 &&
            bytes(customName).length     != 0 &&
            bytes(customRpcUrl).length   != 0 &&
            customChainId                != 0
        ) {
            setChain(customChain, ChainData({
                name    : customName,
                rpcUrl  : customRpcUrl,
                chainId : customChainId
            }));
        }
    }

}

contract DeployForeignFull is ForeignScript {

    using stdJson     for string;
    using ScriptTools for string;

    function run() external {
        setUpNonStandardChains();

        vm.setEnv("FOUNDRY_ROOT_CHAINID",             "1");
        vm.setEnv("FOUNDRY_EXPORTS_OVERWRITE_LATEST", "true");

        string memory chainName = vm.envString("CHAIN");
        string memory fileSlug  = string(abi.encodePacked(chainName, "-", vm.envString("ENV")));
        string memory config    = ScriptTools.loadConfig(fileSlug);

        vm.createSelectFork(getChain(chainName).rpcUrl);

        console.log(string(abi.encodePacked("Deploying ", chainName, " ALMProxy, Controller and RateLimits...")));

        vm.startBroadcast();

        ControllerInstance memory instance = ForeignControllerDeploy.deployFull({
            admin                    : config.readAddress(".admin"),
            psm                      : config.readAddress(".psm"),
            usdc                     : config.readAddress(".usdc"),
            cctp                     : config.readAddress(".cctpTokenMessenger"),
            pendleRouter             : config.readAddress(".pendleRouter"),
            uniswapV3Router          : config.readAddress(".uniswapV3Router"),
            uniswapV3PositionManager : config.readAddress(".uniswapV3PositionManager"),
            midnight                 : config.readAddress(".midnight")
        });

        vm.stopBroadcast();

        console.log("ALMProxy   deployed at", instance.almProxy);
        console.log("Controller deployed at", instance.controller);
        console.log("RateLimits deployed at", instance.rateLimits);

        ScriptTools.exportContract(fileSlug, "almProxy",   instance.almProxy);
        ScriptTools.exportContract(fileSlug, "controller", instance.controller);
        ScriptTools.exportContract(fileSlug, "rateLimits", instance.rateLimits);
    }

}

contract DeployForeignController is ForeignScript {

    using stdJson     for string;
    using ScriptTools for string;

    function run() external {
        setUpNonStandardChains();

        vm.setEnv("FOUNDRY_ROOT_CHAINID",             "1");
        vm.setEnv("FOUNDRY_EXPORTS_OVERWRITE_LATEST", "true");

        string memory chainName = vm.envString("CHAIN");
        string memory fileSlug  = string(abi.encodePacked(chainName, "-", vm.envString("ENV")));
        string memory config    = ScriptTools.loadConfig(fileSlug);

        vm.createSelectFork(getChain(chainName).rpcUrl);

        console.log(string(abi.encodePacked("Deploying ", chainName, " Controller...")));

        vm.startBroadcast();

        address controller = ForeignControllerDeploy.deployController({
            admin                    : config.readAddress(".admin"),
            almProxy                 : config.readAddress(".almProxy"),
            rateLimits               : config.readAddress(".rateLimits"),
            psm                      : config.readAddress(".psm"),
            usdc                     : config.readAddress(".usdc"),
            cctp                     : config.readAddress(".cctpTokenMessenger"),
            pendleRouter             : config.readAddress(".pendleRouter"),
            uniswapV3Router          : config.readAddress(".uniswapV3Router"),
            uniswapV3PositionManager : config.readAddress(".uniswapV3PositionManager"),
            midnight                 : config.readAddress(".midnight")
        });

        vm.stopBroadcast();

        console.log("Controller deployed at", controller);

        ScriptTools.exportContract(fileSlug, "controller", controller);
    }

}

contract DeployMidnightMaker is ForeignScript {

    using stdJson     for string;
    using ScriptTools for string;

    function run() external {
        setUpNonStandardChains();

        vm.setEnv("FOUNDRY_ROOT_CHAINID",             "1");
        vm.setEnv("FOUNDRY_EXPORTS_OVERWRITE_LATEST", "true");

        string memory chainName = vm.envString("CHAIN");
        string memory fileSlug  = string(abi.encodePacked(chainName, "-", vm.envString("ENV")));
        string memory config    = ScriptTools.loadConfig(fileSlug);

        vm.createSelectFork(getChain(chainName).rpcUrl);

        address admin      = config.readAddress(".admin");
        address almProxy   = config.readAddress(".almProxy");
        address controller = config.readAddress(".controller");
        address midnight   = config.readAddress(".midnight");
        address rateLimits = config.readAddress(".rateLimits");
        address quoter     = config.readAddress(".midnightQuoter");

        uint256 maxOfferWindow = config.readUint(".midnightMaxOfferWindow");

        console.log(string(abi.encodePacked("Deploying ", chainName, " Midnight maker contracts...")));

        vm.startBroadcast();

        address ratifier = MidnightMakerDeploy.deployRatifier({
            admin          : admin,
            midnight       : midnight,
            almProxy       : almProxy,
            controller     : controller,
            rateLimits     : rateLimits,
            quoter         : quoter,
            maxOfferWindow : maxOfferWindow
        });

        address fundingStrategy = MidnightMakerDeploy.deployFundingStrategy({
            midnight   : midnight,
            almProxy   : almProxy,
            controller : controller
        });

        vm.stopBroadcast();

        _verify(ratifier, fundingStrategy, midnight, almProxy, controller);

        console.log("MidnightRatifier     deployed at", ratifier);
        console.log("ProxyFundingStrategy deployed at", fundingStrategy);

        ScriptTools.exportContract(fileSlug, "midnightRatifier",        ratifier);
        ScriptTools.exportContract(fileSlug, "midnightFundingStrategy", fundingStrategy);
    }

    function _verify(
        address ratifier,
        address fundingStrategy,
        address midnight,
        address almProxy,
        address controller
    )
        internal view
    {
        require(midnight.code.length   != 0, "DeployMidnightMaker/midnight-not-a-contract");
        require(almProxy.code.length   != 0, "DeployMidnightMaker/proxy-not-a-contract");
        require(controller.code.length != 0, "DeployMidnightMaker/controller-not-a-contract");

        require(
            MidnightRatifier(ratifier).midnight() == midnight &&
            MidnightRatifier(ratifier).proxy() == almProxy &&
            MidnightRatifier(ratifier).controller() == controller,
            "DeployMidnightMaker/ratifier-wiring-mismatch"
        );

        require(
            ProxyFundingStrategy(fundingStrategy).midnight() == midnight &&
            ProxyFundingStrategy(fundingStrategy).proxy() == almProxy &&
            ProxyFundingStrategy(fundingStrategy).controller() == controller,
            "DeployMidnightMaker/strategy-wiring-mismatch"
        );
    }

}
