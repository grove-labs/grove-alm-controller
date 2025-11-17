// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IMerklDistributorLike } from "../interfaces/MerklInterfaces.sol";

struct MerklToggleOperatorParams {
    IALMProxy             proxy;
    IMerklDistributorLike distributor;
    address               operator;
}

library MerklLib {

    function toggleOperator(MerklToggleOperatorParams memory params) external {
        params.proxy.doCall(
            address(params.distributor),
            abi.encodeCall(distributor.toggleOperator, (address(this), params.operator))
        );
    }

}
