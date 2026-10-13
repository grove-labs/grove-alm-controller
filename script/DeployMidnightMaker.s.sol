// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { ScriptTools } from "dss-test/ScriptTools.sol";

import "forge-std/Script.sol";

import { MidnightMakerDeploy } from "../deploy/MidnightMakerDeploy.sol";

import { MidnightRatifier }     from "../src/MidnightRatifier.sol";
import { ProxyFundingStrategy } from "../src/ProxyFundingStrategy.sol";

import { ForeignScript } from "./Deploy.s.sol";

contract DeployMidnightRatifier is ForeignScript {

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

        require(midnight.code.length   != 0, "DeployMidnightRatifier/midnight-not-a-contract");
        require(almProxy.code.length   != 0, "DeployMidnightRatifier/proxy-not-a-contract");
        require(controller.code.length != 0, "DeployMidnightRatifier/controller-not-a-contract");
        require(rateLimits.code.length != 0, "DeployMidnightRatifier/rate-limits-not-a-contract");

        console.log(string(abi.encodePacked("Deploying ", chainName, " MidnightRatifier...")));

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

        vm.stopBroadcast();

        require(
            MidnightRatifier(ratifier).midnight()   == midnight   &&
            MidnightRatifier(ratifier).proxy()      == almProxy   &&
            MidnightRatifier(ratifier).controller() == controller &&
            MidnightRatifier(ratifier).quoter()     == quoter,
            "DeployMidnightRatifier/wiring-mismatch"
        );

        console.log("MidnightRatifier deployed at", ratifier);

        ScriptTools.exportContract(fileSlug, "midnightRatifier", ratifier);
    }

}

contract DeployProxyFundingStrategy is ForeignScript {

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

        address almProxy   = config.readAddress(".almProxy");
        address controller = config.readAddress(".controller");
        address midnight   = config.readAddress(".midnight");

        require(midnight.code.length   != 0, "DeployProxyFundingStrategy/midnight-not-a-contract");
        require(almProxy.code.length   != 0, "DeployProxyFundingStrategy/proxy-not-a-contract");
        require(controller.code.length != 0, "DeployProxyFundingStrategy/controller-not-a-contract");

        console.log(string(abi.encodePacked("Deploying ", chainName, " ProxyFundingStrategy...")));

        vm.startBroadcast();

        address fundingStrategy = MidnightMakerDeploy.deployFundingStrategy({
            midnight   : midnight,
            almProxy   : almProxy,
            controller : controller
        });

        vm.stopBroadcast();

        require(
            ProxyFundingStrategy(fundingStrategy).midnight()   == midnight   &&
            ProxyFundingStrategy(fundingStrategy).proxy()      == almProxy   &&
            ProxyFundingStrategy(fundingStrategy).controller() == controller,
            "DeployProxyFundingStrategy/wiring-mismatch"
        );

        console.log("ProxyFundingStrategy deployed at", fundingStrategy);

        ScriptTools.exportContract(fileSlug, "midnightFundingStrategy", fundingStrategy);
    }

}
