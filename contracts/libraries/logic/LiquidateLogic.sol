// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SToken} from "../../protocol/SToken.sol";
import {NFTOracle} from "../../protocol/NFTOracle.sol";
import {DataTypes} from "../types/DataTypes.sol";
import {ICollateralPoolLoan} from "../../interfaces/ICollateralPoolLoan.sol";
import {ICollateralPoolHandler} from "../../interfaces/ICollateralPoolHandler.sol";
import {ICollateralPoolAddressesProvider} from "../../interfaces/ICollateralPoolAddressesProvider.sol";

library LiquidateLogic {
    event Redeem(
        address indexed user,
        uint256 indexed repayAmount,
        uint256 indexed repayETH,
        address nftAsset,
        uint256 nftTokenId,
        uint256 loanId
    );

    event Liquidate(
        address indexed user,
        address nftAsset,
        uint256 nftTokenId,
        uint256 loanId,
        uint256 liquidateRequireAmount,
        uint256 refundAmount,
        uint256 healthFactor
    );

    struct RedeemLocalVars {
        address initiator;
        address poolLoan;
        address handler;
        uint256 loanId;
        uint256 repayAmount;
        uint256 sendETHAmount;
    }

    struct LiquidateLocalVars {
        address initiator;
        address poolLoan;
        address nftOracle;
        address handler;
        uint256 loanId;
        uint256 collateralPrice;
        uint256 healthFactor;
        uint256 liquidateRequireAmount;
        uint256 refundAmount;
        uint256 sendETHAmount;
    }

    function executeRedeem(
        ICollateralPoolAddressesProvider addressesProvider,
        SToken sToken,
        DataTypes.ExecuteRedeemParams memory params
    ) external returns (uint256) {
        RedeemLocalVars memory vars;
        vars.initiator = params.initiator;
        vars.sendETHAmount = msg.value;
        vars.poolLoan = addressesProvider.getCollateralPoolLoan();
        vars.loanId = ICollateralPoolLoan(vars.poolLoan).getCollateralLoanId(params.nftAsset, params.nftTokenId);
        require(vars.loanId != 0, "NFT is not collateral");

        DataTypes.LoanData memory loanData = ICollateralPoolLoan(vars.poolLoan).getLoan(vars.loanId);
        require(loanData.initiator == vars.initiator, "Not NFT owner");
        require(sToken.balanceOf(vars.initiator) + vars.sendETHAmount >= loanData.rewardAmount, "Not enough balance for redeem");

        vars.repayAmount = loanData.rewardAmount - vars.sendETHAmount;

        sToken.transferFrom(vars.initiator, address(this), vars.repayAmount);    
        IERC721(params.nftAsset).safeTransferFrom(address(this), vars.initiator ,params.nftTokenId);
        ICollateralPoolLoan(vars.poolLoan).deleteLoan(vars.initiator, params.nftAsset, params.nftTokenId);

        emit Redeem(
            vars.initiator,
            vars.repayAmount,
            vars.sendETHAmount,
            params.nftAsset,
            params.nftTokenId,
            vars.loanId
        );

        return vars.repayAmount;
    }

    function executeLiquidate(
        ICollateralPoolAddressesProvider addressesProvider,
        SToken sToken,
        DataTypes.ExecuteLiquidateParams memory params
    ) external {
        LiquidateLocalVars memory vars;
        vars.initiator = params.initiator;
        vars.sendETHAmount = msg.value;
        vars.nftOracle = addressesProvider.getNftOracle();
        vars.poolLoan = addressesProvider.getCollateralPoolLoan();
        vars.handler = addressesProvider.getCollateralPoolHandler();
        vars.loanId = ICollateralPoolLoan(vars.poolLoan).getCollateralLoanId(params.nftAsset, params.nftTokenId);
        vars.healthFactor = ICollateralPoolLoan(vars.poolLoan).getNftAssetHealthFactor(params.nftAsset, params.nftTokenId);
        DataTypes.LoanData memory loanData = ICollateralPoolLoan(vars.poolLoan).getLoan(vars.loanId);
        uint256 liquidationIcentive = ICollateralPoolHandler(vars.handler).getLiquidationIncentive();     
        vars.liquidateRequireAmount = vars.collateralPrice * (1e18 - liquidationIcentive) / 1e18; 
        uint256 collateralizerBalance = sToken.balanceOf(loanData.initiator);

        require(vars.loanId != 0, "NFT is not collateral");
        require(vars.healthFactor < 1 * 1e18, "Liquidation cannot be executed, health factor must be less than 1");
        require(vars.sendETHAmount >= vars.liquidateRequireAmount, "Not enough balance for liquidation");

        // Refund ETH to the collateralizer
        if(loanData.rewardAmount > collateralizerBalance){
            vars.refundAmount = vars.liquidateRequireAmount - (loanData.rewardAmount - collateralizerBalance);
            sToken.burn(loanData.initiator, collateralizerBalance);
        }else{
            vars.refundAmount = vars.liquidateRequireAmount;
            sToken.burn(loanData.initiator, loanData.rewardAmount);   
        }
        (bool success, ) = (loanData.initiator).call{value: vars.refundAmount}("");
        require(success, "Refund ETH failed");

        IERC721(params.nftAsset).safeTransferFrom(address(this), vars.initiator ,params.nftTokenId);
        ICollateralPoolLoan(vars.poolLoan).deleteLoan(vars.initiator, params.nftAsset, params.nftTokenId);

        emit Liquidate(
            vars.initiator,
            params.nftAsset,
            params.nftTokenId,
            vars.loanId,
            vars.liquidateRequireAmount,
            vars.refundAmount,
            vars.healthFactor
        );
    }
}