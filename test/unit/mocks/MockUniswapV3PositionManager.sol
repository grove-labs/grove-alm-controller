// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { INonfungiblePositionManager } from "../../../src/interfaces/UniswapV3Interfaces.sol";

contract MockPositionManagerBase is INonfungiblePositionManager {
    address internal immutable proxyOwner;

    constructor(address owner_) {
        proxyOwner = owner_;
    }

    function mint(MintParams calldata)
        external
        virtual
        override
        returns (uint256, uint128, uint256, uint256)
    {
        revert("MockPositionManager/not-implemented");
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata)
        external
        virtual
        override
        returns (uint128, uint256, uint256)
    {
        revert("MockPositionManager/not-implemented");
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata)
        external
        virtual
        override
        returns (uint256, uint256)
    {
        revert("MockPositionManager/not-implemented");
    }

    function collect(CollectParams calldata)
        external
        virtual
        override
        returns (uint256, uint256)
    {
        revert("MockPositionManager/not-implemented");
    }

    function ownerOf(uint256) external view virtual override returns (address) {
        return proxyOwner;
    }

    function positions(uint256)
        external
        view
        virtual
        override
        returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24,
            int24,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        revert("MockPositionManager/not-implemented");
    }
}

contract MockPositionManagerZeroLiquidity is MockPositionManagerBase {
    constructor(address owner_) MockPositionManagerBase(owner_) { }

    function mint(MintParams calldata)
        external
        pure
        override
        returns (uint256, uint128, uint256, uint256)
    {
        return (1, 0, 0, 0);
    }
}

contract MockPositionManagerPositionsCallFailure is MockPositionManagerBase {
    constructor(address owner_) MockPositionManagerBase(owner_) { }

    function positions(uint256)
        external
        view
        override
        returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24,
            int24,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        revert("MockPositionManager/positions-call-failed");
    }
}

contract MockPositionManagerPositionsShortReturn is MockPositionManagerBase {
    constructor(address owner_) MockPositionManagerBase(owner_) { }

    function positions(uint256)
        external
        view
        override
        returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24,
            int24,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        assembly {
            mstore(0x00, 0)
            return(0x00, 64)
        }
    }
}
