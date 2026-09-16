// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IALMProxy }             from "../interfaces/IALMProxy.sol";
import { IRateLimits }           from "../interfaces/IRateLimits.sol";
import { IMerklDistributorLike } from "../interfaces/MerklInterfaces.sol";

import { RateLimitHelpers } from "../RateLimitHelpers.sol";

library MerklLib {

    bytes32 public constant LIMIT_MERKL_TOGGLE_OPERATOR = keccak256("LIMIT_MERKL_TOGGLE_OPERATOR");

    struct MerklToggleOperatorParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        address     distributor;
        address     operator;
    }

    function toggleOperator(MerklToggleOperatorParams memory params) external {
        // Exists-only gate: keccak256(abi.encode(LIMIT_MERKL_TOGGLE_OPERATOR, operator, distributor)).
        require(
            params.rateLimits.getRateLimitData(
                RateLimitHelpers.makeAddressAddressKey(
                    LIMIT_MERKL_TOGGLE_OPERATOR,
                    params.operator,
                    params.distributor
                )
            ).maxAmount > 0,
            "MerklLib/invalid-action"
        );

        params.proxy.doCall(
            params.distributor,
            abi.encodeCall(IMerklDistributorLike.toggleOperator, (address(params.proxy), params.operator))
        );
    }

}
