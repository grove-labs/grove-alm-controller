// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { MidnightRatifier }     from "../src/MidnightRatifier.sol";
import { ProxyFundingStrategy } from "../src/ProxyFundingStrategy.sol";

library MidnightMakerDeploy {

    function deployRatifier(
        address admin,
        address midnight,
        address almProxy,
        address controller,
        address rateLimits,
        address quoter,
        uint256 maxOfferWindow
    )
        internal returns (address ratifier)
    {
        ratifier = address(new MidnightRatifier({
            admin_          : admin,
            midnight_       : midnight,
            proxy_          : almProxy,
            controller_     : controller,
            rateLimits_     : rateLimits,
            quoter_         : quoter,
            maxOfferWindow_ : maxOfferWindow
        }));
    }

    function deployFundingStrategy(address midnight, address almProxy, address controller)
        internal returns (address strategy)
    {
        strategy = address(new ProxyFundingStrategy({
            midnight_   : midnight,
            proxy_      : almProxy,
            controller_ : controller
        }));
    }

}
