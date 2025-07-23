
import { IERC7540 } from "forge-std/interfaces/IERC7540.sol";

interface ICentrifugeToken is IERC7540 {
    function cancelDepositRequest(uint256 requestId, address controller) external;
    function cancelRedeemRequest(uint256 requestId, address controller) external;
    function claimCancelDepositRequest(uint256 requestId, address receiver, address controller)
        external returns (uint256 assets);
    function claimCancelRedeemRequest(uint256 requestId, address receiver, address controller)
        external returns (uint256 shares);
}

interface ICentrifugeV3Vault {
    function manager() external view returns (address);
    function share() external view returns (address);
    function poolId() external view returns (uint64);
    function scId() external view returns (bytes16);
}

interface IAsyncRedeemManagerLike {
    function spoke() external view returns (address);
}

interface ISpokeLike {
    function crosschainTransferShares(
        uint16 centrifugeId,
        uint64 poolId,
        bytes16 scId,
        bytes32 receiver,
        uint128 amount,
        uint128 remoteExtraGasLimit
    ) external payable;
}
