pragma solidity ^0.8.28;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {BitLib} from '@mangrovedao/mangrove-core/lib/core/BitLib.sol';
import {MathLib, WAD} from '@morpho-org/morpho-blue/src/libraries/MathLib.sol';

import {Convert} from 'contracts/libraries/Convert.sol';
import {Uint16Set} from 'contracts/libraries/Uint16Set.sol';
import {TickMath} from 'contracts/libraries/TickMath.sol';
import {
    B_IN_Q72,
    BIPS,
    MAG2,
    MAG4,
    MAG6,
    MINIMUM_LIQUIDITY,
    Q16,
    Q32,
    Q64,
    Q72,
    Q112,
    Q128,
    Q144,
    TRANCHE_B_IN_Q72,
    TRANCHE_QUARTER_B_IN_Q72,
    SAT_PERCENTAGE_DELTA_DEFAULT_WAD,
    SAT_PERCENTAGE_DELTA_4_WAD,
    SAT_PERCENTAGE_DELTA_5_WAD,
    SAT_PERCENTAGE_DELTA_6_WAD,
    SAT_PERCENTAGE_DELTA_7_WAD,
    SAT_PERCENTAGE_DELTA_8_WAD,
    ZERO_ADDRESS,
    MAX_SATURATION_PERCENT_IN_WAD,
    MAX_UTILIZATION_PERCENT_IN_WAD,
    LIQUIDITY_INTEREST_RATE_MAGNIFICATION
} from 'contracts/libraries/constants.sol';
import {Liquidation} from 'contracts/libraries/Liquidation.sol';
import {Validation} from 'contracts/libraries/Validation.sol';
import {
    DEPOSIT_L,
    DEPOSIT_X,
    DEPOSIT_Y,
    BORROW_L,
    BORROW_X,
    BORROW_Y,
    ROUNDING_UP
} from 'contracts/interfaces/tokens/ITokenController.sol';
import {Interest} from 'contracts/libraries/Interest.sol';

/**
 * @title   A lib to maintain the saturation of all the positions
 * @author  imi@1m1.io
 * @author  Will duelingGalois@protonmail.com
 * @notice  Saturation (=sat) is defined as the net borrow. In theory, we would want to divide net
 *  borrow by the total liquidity; in practice, we keep the net borrow only in the tree. The unit
 *  of sat is relative to active liquidity assets, or the amount of L deposited less the amount
 *  borrowed.
 *
 *  When we determine how much a swap moves the price, or square root price, we can define our
 *  equation using ticks, or tranches (100 ticks), where for some base $b$, the square root price
 *  is $b^t$ for some tick $t$. Alternatively for a larger base $B = b^{100}$ we can define the
 *  square root price as $B^T$ for some tranche $T$. Using the square root price, we can define the
 *  amount of x or y in each tranche as $x =  LB^{T_0} - LB^{T_1} $ and $y= \frac{L}{ B^{T_1}} -
 *  \frac{L}{ B^{T_0}}$, where liquidity is $L = \sqrt{reserveX \cdot reserveY}$. If we want to
 *  know how much debt of x or y can be liquidated within one tranche, we can solve these equations
 *  for L and then the amount of x and y are considered the debt we would like to see if it could
 *  be liquidated in one tranche.  If saturation with respect to our starting $L$ is smaller, that
 *  amount of debt can be liquidated in one swap in the given tranche. Otherwise it is to big and
 *  can not. Note that we assume $T_1 \text{ and } T_0 \in \mathbb{Z}
 *  $ and $T_0 + 1 = T_1$. Then our definition of saturation relative to L is as follows,
 *
 *  ```math
 *    \begin{equation}
 *      saturationRelativeToL =
 *        \begin{cases}
 *          \frac{debtX}{B^{T_{1}}}\left(\frac{B}{B-1}\right) \\
 *          debtY\cdot B^{T_{0}}\cdot\left(\frac{B}{B-1}\right)
 *        \end{cases}
 *    \end{equation}
 *   ```
 *
 *  Saturation is kept in a tree, starting with a root, levels and leafs. We keep 2 trees, one for
 *  net X borrows, another for net Y borrows. The price is always the price of Y in units of X.
 *  Mostly, the code works with the sqrt of price. A net X borrow refers to a position that if
 *  liquidated would cause the price to become smaller; the opposite for net Y positions. Ticks are
 *  along the price dimension and int16. Tranches are 100 ticks, stored as int16.
 *
 *  Leafs (uint16) split the sat, which is uint112, into intervals. From left to right, the leafs
 *  of the tree cover the sat space in increasing order. Each account with a position has a price
 *  at which its LTV would reach LTVMAX, which is its liquidation (=liq) price.
 *
 *  To place a debt into the appropriate tranche, we think of each debt and its respective
 *  collateral as a serries of sums, where each item in the series fits in one tranche. Using
 *  formulas above, we determine the number of ticks a debt would cross if liquidated. This is
 *  considered the span of the liquidation. Using this value we then determine the start and end
 *  points of the liquidation, where the start would be closer to the prices, on the right of the
 *  end for net debt of x and on the left of the end for net debt of Y.
 *
 *   Once we have the liquidation start, end, and span, we begin to place the debt, one tranche at
 *  a time moving towards the price. In this process we compare the prior recorded saturation and
 *  allow the insertion up to some max, set at 90% or the configuration set by the user.
 *
 *  A Tranche contains multiple accounts and thus a total sat. The tranches' sat assigns it to a
 *  leaf. Each leaf can contain multiple tranches and thus has a total actual sat whilst
 *  representing a specific sat per tranche range. Leafs and thus tranches and thus accounts above
 *  a certain sat threshold are considered over saturated. These accounts are penalized for being
 *  in an over saturated tranche. Each account, tranche and leaf has a total penalty that needs to
 *  be repaid to flatten the position fully. Sat is distributed over multiple tranches, in case a
 *  single tranche does not have enough available sat left. Sat is kept cumulatively in the tree,
 *  meaning a node contains the sum of the sat of its parents. Updating a sat at the  bottom of the
 *  tree requires updating all parents. Penalty is kept as a path sum, in uints of LAssets, meaning
 *  the penalty of an account is the sum of the penalties of all its parents. Updating the penalty
 *  for a range of leafs only requires updating the appropriate parent. Position (=pos) refers to
 *  the relative index of a child within its parent. Index refers to the index of a node in within
 *  its level
 */
library Saturation {
    // constants

    // time budget add to sat before adding it to the tree; compensates for the fact that the liq price moves closer to the current price over time
    uint256 internal constant SATURATION_TIME_BUFFER_IN_MAG2 = 101;
    // percentage of max sat per tranche considered healthy; max sat per tranche is liquidity*(B-1)/2 with B the tranche basis, which is the max sat such that the liquidation would not cause a swap larger than a tranche
    uint256 internal constant MAX_SATURATION_RATIO_IN_MAG2 = 95;
    // percentage of max sat per tranche where penalization begins
    uint256 internal constant START_SATURATION_PENALTY_RATIO_IN_MAG2 = 85;
    uint256 internal constant MAX_INITIAL_SATURATION_MAG2 = 90;
    // The amount of LTV we expect liquidations to occur at
    uint256 internal constant EXPECTED_SATURATION_LTV_MAG2 = 85;

    // EXPECTED_SATURATION_LTV_MAG2 * SATURATION_TIME_BUFFER_IN_MAG2 ** 2
    uint256 internal constant EXPECTED_SATURATION_LTV_MAG2_TIMES_SAT_BUFFER_SQUARED = 867_085;

    uint256 internal constant EXPECTED_SATURATION_LTV_PLUS_ONE_MAG2 = 185;
    // percentage of sat used as penalty
    uint256 private constant PENALTY_FACTOR_IN_MAG2 = 10;

    uint256 private constant SAT_CHANGE_OF_BASE_Q128 = 0xa39713406ef781154a9e682c2331a7c03;
    uint256 private constant SAT_CHANGE_OF_BASE_TIMES_SHIFT = 0xb3f2fb93ad437464387b0c308d1d05537;
    // tick offset added to ensure leaf calculation starts from 0 at the lowest leaf
    int16 private constant TICK_OFFSET = 1112;
    uint256 internal constant LOWEST_POSSIBLE_IN_PENALTY = 0xd9999999999999999999999999999999; //MAX_ASSETS * START_SATURATION_PENALTY_RATIO_IN_MAG2 / TICKS_PER_TRANCHE;
    uint256 private constant MIN_LIQ_TO_REACH_PENALTY = 850; // MINIMUM_LIQUIDITY * START_SATURATION_PENALTY_RATIO_IN_MAG2 / TICKS_PER_TRANCHE;

    // convenience since 1 is interpreted as uint8 by solc
    int256 private constant INT_ONE = 1;
    int256 private constant INT_NEGATIVE_ONE = -1;
    int256 private constant INT_ZERO = 0;

    // leafs are on level LEVELS_WITHOUT_LEAFS; root is level 0
    uint256 internal constant LEVELS_WITHOUT_LEAFS = 3;
    // for convenience, since used a lot, ==LEVELS_WITHOUT_LEAFS - 1
    uint256 internal constant LOWEST_LEVEL_INDEX = 2;
    // 1 << LEAFS_IN_BITS
    uint256 internal constant LEAFS = 4096;

    // 1 << 4
    uint256 internal constant CHILDREN_PER_NODE = 16;
    //1 << (2 * 4)
    uint256 private constant CHILDREN_AT_THIRD_LEVEL = 256;

    // Bt = (1 - 2^-9)^-1 is the base for ticks, then the tranche base is BT = Bt^TICKS_PER_TRANCHE, int only to not need casting below, == TICKS_PER_TRANCHE
    int256 private constant TICKS_PER_TRANCHE = 100;
    // for convenience, used to determine max sat per tranche to not cross in liq swap: B/(B-1)
    uint256 constant TRANCHE_BASE_OVER_BASE_MINUS_ONE_Q72 = 0x5a19b9039a07efd7b39;
    // TickMath.MIN_TICK / TICKS_PER_TRANCHE - 1; // -1 to floor
    int256 internal constant MIN_TRANCHE = -199;
    // TickMath.MAX_TICK / TICKS_PER_TRANCHE;
    int256 internal constant MAX_TRANCHE = 198;

    // constants for bit reading and writing in nodes
    // type(uint256).max >> (TOTAL_BITS - FIELD_BITS);
    uint256 private constant FIELD_NODE_MASK = 0xffff;

    // Buffer space (in tranches) allowed above the highest used tranche before hitting maxLeaf limit
    uint8 internal constant SATURATION_MAX_BUFFER_TRANCHES = 3;
    uint256 private constant QUARTER_MINUS_ONE = 24;
    uint256 private constant QUARTER_OF_MAG2 = 25;
    uint256 private constant NUMBER_OF_QUARTERS = 4;
    // We make the penalty slightly larger to hit our desired premium for exceeding the time buffer.
    uint256 private constant SOFT_LIQUIDATION_SCALER = 10_020;

    // 2 * 2**64 * 2, used in saturation formula.
    uint256 private constant TWO_Q64 = 0x20000000000000000;
    // 4 * 2**128, needed in quadratic formula is saturation.
    uint256 private constant FOUR_Q128 = 0x400000000000000000000000000000000;

    // MAG4 * Q64 constant needed in formula.
    uint256 private constant MAG4_TIMES_Q64 = 0x27100000000000000000;

    // B_Q72 - 1 constant needed in formula.
    uint256 private constant B_Q72_MINUS_ONE = 0x1008040201008040200;

    // errors

    // if the largest sat in the trees is too large
    error MaxTrancheOverSaturated();
    // Attempt to update zero address
    error CannotUpdateZeroAddress();

    // storage structs

    // final structure containing all the storage data
    struct SaturationStruct {
        // the tree containing sat and penalties for netX sat
        Tree netXTree;
        // the tree containing sat and penalties for netY sat
        Tree netYTree;
        uint16 maxLeaf;
    }

    /**
     * @notice a pair of saturation values used and stored throughout this library.
     */
    struct SaturationPair {
        // the value of a debt in units of L assets at a given liquidation price.
        uint128 satInLAssets;
        // the amount of active liquidity assets, L, that the swap required to liquidate the debt
        // would consume.
        uint128 satRelativeToL;
    }

    // the main tree struct
    struct Tree {
        // is this tree netX xor not
        bool netX;
        // highest leaf that contains a tranche/account in the tree, useful to quickly decide whether the entire tree is over saturated
        uint16 highestSetLeaf;
        // nodes per level, each node contains a bit field of size of the number of its children and a uint112 saturation
        uint128 totalSatInLAssets;
        uint256 tranchesWithSaturation;
        uint256[][LEVELS_WITHOUT_LEAFS] nodes;
        // last level of nodes is kept as leafs
        Leaf[LEAFS] leafs;
        // which leaf does a tranche belong to
        mapping(int16 => uint16) trancheToLeaf;
        // sat per tranche
        mapping(int16 => SaturationPair) trancheToSaturation;
        // data per account
        mapping(address => Account) accountData;
    }

    // a leaf contains multiple tranches and contains the total sat and penalty for the leaf
    struct Leaf {
        // set of tranches in a leaf
        Uint16Set.Set tranches;
        // sum of sat of each tranche in this leaf
        SaturationPair leafSatPair;
        // penalty for the leaf
        uint256 penaltyInBorrowLSharesPerSatInQ72;
    }

    // basic data per account
    struct Account {
        // does account exist, needed as accountToTranche has default value 0 and tranche 0 is ok
        bool exists;
        // tranche that account belongs to
        int16 lastTranche;
        // penalty of account
        uint112 penaltyInBorrowLShares;
        // sat per tranche starting at `tranche` and running in the direction dictated by
        // netX/netY; netX trees have us distributing sat over increasing tranches, netY over
        // decreasing tranches, in both cases, towards the current price
        SaturationPair[] satPairPerTranche;
        // penalty per sat per tranche starting at `tranche` and running in the direction dictated
        // by netX/netY; netX trees have us distributing sat over increasing tranches, netY over
        // decreasing tranches, in both cases, towards the current price
        uint256[] treePenaltyAtOnsetInBorrowLSharesPerSatInQ72PerTranche;
    }

    // memory structs

    struct CalcLiqSqrtPriceHandleAllABCNonZeroStruct {
        int256 netLInMAG2;
        int256 netXInMAG2;
        int256 netYInMAG2;
        uint256 netYAbsInMAG2;
        uint256 borrowedXAssets;
        uint256 borrowedYAssets;
    }

    struct AddSatToTrancheStateUpdatesStruct {
        int256 tranche;
        uint256 newLeaf;
        SaturationPair oldTrancheSaturation;
        SaturationPair newTrancheSaturation;
        SaturationPair satAvailableToAdd;
        address account;
    }

    // init functions

    /**
     * @notice  initializes the satStruct, allocating storage for all nodes
     * @dev     initCheck can be removed once the tree structure is fixed
     * @param   satStruct contains the entire sat data
     */
    function initializeSaturationStruct(
        SaturationStruct storage satStruct
    ) internal {
        // init nodes in storage
        initTree(satStruct.netXTree);
        // init nodes in storage
        initTree(satStruct.netYTree);
        // set 1 of the tree to netX, the other stays netY by default
        satStruct.netXTree.netX = true;
    }

    /**
     * @notice  init the nodes of the tree
     * @param   tree that is being read from or written to
     */
    function initTree(
        Tree storage tree
    ) internal {
        tree.nodes[0] = new uint256[](1);
        tree.nodes[1] = new uint256[](CHILDREN_PER_NODE);
        tree.nodes[2] = new uint256[](CHILDREN_AT_THIRD_LEVEL);
    }

    // update functions

    /**
     * @notice  update the borrow position of an account and potentially check (and revert) if the resulting sat is too high
     * @dev     run accruePenalties before running this function
     * @param   satStruct  main data struct
     * @param   inputParams  contains the position and pair params, like account borrows/deposits, current price and active liquidity
     * @param   account  for which is position is being updated
     */
    function update(
        SaturationStruct storage satStruct,
        Validation.InputParams memory inputParams,
        address account,
        uint256 userSaturationRatioMAG2
    ) internal {
        if (account == ZERO_ADDRESS) revert CannotUpdateZeroAddress();

        // if activeLiquidity means there cannot be any sat, but it could be getting repaid
        if (inputParams.activeLiquidityAssets == 0) {
            // if the account has a position, we need to remove it from the tree
            if (satStruct.netXTree.accountData[account].exists) {
                removeSatFromTranche(satStruct.netXTree, account, INT_ONE);
            }
            if (satStruct.netYTree.accountData[account].exists) {
                removeSatFromTranche(satStruct.netYTree, account, INT_NEGATIVE_ONE);
            }
        } else {
            // calc the netX and netY prices where the position would reach LTVMAX
            (uint256 netXLiqSqrtPriceInXInQ72, uint256 netYLiqSqrtPriceInXInQ72) =
                calcLiqSqrtPriceQ72(inputParams.userAssets);

            uint256 sqrtPriceMinInQ72 = inputParams.sqrtPriceMinInQ72;
            uint256 sqrtPriceMaxInQ72 = inputParams.sqrtPriceMaxInQ72;

            // if a netX exists, update the netX tree
            if (0 < netXLiqSqrtPriceInXInQ72) {
                inputParams.sqrtPriceMinInQ72 = netXLiqSqrtPriceInXInQ72;
                inputParams.sqrtPriceMaxInQ72 = netXLiqSqrtPriceInXInQ72;
                (int256 endOfLiquidationInTicks, SaturationPair memory saturation) =
                    calcLastTrancheAndSaturation(inputParams, netXLiqSqrtPriceInXInQ72, userSaturationRatioMAG2, true);
                updateTreeGivenAccountTrancheAndSat(
                    satStruct.netXTree,
                    saturation,
                    account,
                    endOfLiquidationInTicks,
                    inputParams.activeLiquidityAssets,
                    userSaturationRatioMAG2
                );
            }

            // if a netY exists, update the netY tree
            if (0 < netYLiqSqrtPriceInXInQ72) {
                inputParams.sqrtPriceMinInQ72 = netYLiqSqrtPriceInXInQ72;
                inputParams.sqrtPriceMaxInQ72 = netYLiqSqrtPriceInXInQ72;
                (int256 endOfLiquidationInTicks, SaturationPair memory saturation) =
                    calcLastTrancheAndSaturation(inputParams, netYLiqSqrtPriceInXInQ72, userSaturationRatioMAG2, false);
                updateTreeGivenAccountTrancheAndSat(
                    satStruct.netYTree,
                    saturation,
                    account,
                    endOfLiquidationInTicks,
                    inputParams.activeLiquidityAssets,
                    userSaturationRatioMAG2
                );
            }

            // reset sqrtPrice values in case struct is reused.
            inputParams.sqrtPriceMinInQ72 = sqrtPriceMinInQ72;
            inputParams.sqrtPriceMaxInQ72 = sqrtPriceMaxInQ72;

            uint256 maxLeaf = satToLeaf(inputParams.activeLiquidityAssets);
            // check whether the max sat is too high
            if (
                maxLeaf
                    < Math.max(satStruct.netXTree.highestSetLeaf, satStruct.netYTree.highestSetLeaf)
                        + SATURATION_MAX_BUFFER_TRANCHES
            ) {
                revert MaxTrancheOverSaturated();
            }

            satStruct.maxLeaf = uint16(maxLeaf);
        }
    }

    /**
     * @notice  internal update that removes the account from the tree (if it exists) from its prev position and adds it to its new position
     * @param   tree that is being read from or written to
     * @param   newSaturation  the new sat of the account, in units of LAssets (absolute) and relative to active liquidity
     * @param   account  whos position is being considered
     * @param   newEndOfLiquidationInTicks the new tranche of the account in mag2.
     * @param   activeLiquidityInLAssets  of the pair
     */
    function updateTreeGivenAccountTrancheAndSat(
        Tree storage tree,
        SaturationPair memory newSaturation,
        address account,
        int256 newEndOfLiquidationInTicks,
        uint256 activeLiquidityInLAssets,
        uint256 userSaturationRatioMAG2
    ) internal {
        // in which direction do we distribute the sat
        int256 trancheDirection = tree.netX ? INT_ONE : INT_NEGATIVE_ONE;

        // flag whether the highest sat needs updating
        bool highestSetLeafRemoved;
        bool highestSetLeafAdded;

        // if account exists at all, remove from the tree
        if (tree.accountData[account].exists) {
            highestSetLeafRemoved = removeSatFromTranche(tree, account, trancheDirection);
        }

        // if the account has any sat, add to the tree
        if (0 < newSaturation.satRelativeToL) {
            highestSetLeafAdded = addSatToTranche(
                tree,
                account,
                trancheDirection,
                newEndOfLiquidationInTicks,
                newSaturation,
                activeLiquidityInLAssets,
                userSaturationRatioMAG2
            );
        }

        // update highestSetLeaf
        if (highestSetLeafRemoved && !highestSetLeafAdded) {
            unchecked {
                tree.highestSetLeaf =
                    uint16(findHighestSetLeafUpwards(tree, LOWEST_LEVEL_INDEX, tree.highestSetLeaf / CHILDREN_PER_NODE));
            }
        }
    }

    /**
     * @notice  remove sat from tree, for each tranche in a loop that could hold sat for the account
     * @param   tree that is being read from or written to
     * @param   account whos position is being considered
     * @param   trancheDirection  direction of sat distribution depending on netX/netY
     * @return  highestSetLeafRemoved  flag indicating whether we removed sat from the highest leaf xor not
     */
    function removeSatFromTranche(
        Tree storage tree,
        address account,
        int256 trancheDirection
    ) internal returns (bool highestSetLeafRemoved) {
        // beginning tranche
        int256 tranche = tree.accountData[account].lastTranche;
        uint256 satArrayLength = tree.accountData[account].satPairPerTranche.length;
        // loop through each tranche that could contain sat, we cannot short circuit as we might have added sat to the last tranche
        for (uint256 trancheIndex = 0; trancheIndex < satArrayLength; trancheIndex++) {
            // if we have reached the edges of price, we are definitely done
            if (MAX_TRANCHE < tranche || tranche < MIN_TRANCHE) break;

            SaturationPair memory oldAccountSaturationInTranche =
                tree.accountData[account].satPairPerTranche[trancheIndex];
            // if the account had no sat in this tranche, move to next tranche
            if (0 < oldAccountSaturationInTranche.satRelativeToL) {
                // remember old leaf before state update
                uint256 oldLeaf = tree.trancheToLeaf[int16(tranche)];

                // update sat, fields and penalties for leafs, parents
                removeSatFromTrancheStateUpdates(
                    tree, oldAccountSaturationInTranche, tranche, oldLeaf, account, trancheIndex
                );

                uint256 highestSetLeaf = tree.highestSetLeaf;
                bool isLeafEmpty = Uint16Set.count(tree.leafs[highestSetLeaf].tranches) == 0;
                if (oldLeaf == highestSetLeaf && isLeafEmpty) {
                    highestSetLeafRemoved = true;
                }
            }

            // move to next tranche
            unchecked {
                tranche += trancheDirection;
            }
        }
        // we have removed the account from the tree and update the state of the account
        delete tree.accountData[account];
    }

    /**
     * @notice  depending on old and new leaf of the tranche, update the sats, fields and penalties of the tree
     * @param   tree that is being read from or written to
     * @param   oldAccountSaturationInTranche account sat
     * @param   tranche  under consideration
     * @param   oldLeaf where tranche was located before this sat removal
     * @param   account  needed to accrue penalty
     * @param   trancheIndex which tranche of the account are we handling?
     */
    function removeSatFromTrancheStateUpdates(
        Tree storage tree,
        SaturationPair memory oldAccountSaturationInTranche,
        int256 tranche,
        uint256 oldLeaf,
        address account,
        uint256 trancheIndex
    ) internal {
        // old sat of tranche (both absolute and relative)
        SaturationPair memory oldTrancheSaturation = tree.trancheToSaturation[int16(tranche)];

        // tranche sat decreases by removed account sat, account can not be greater than tranche of accounts
        SaturationPair memory newTrancheSaturation;
        unchecked {
            newTrancheSaturation.satRelativeToL =
                oldTrancheSaturation.satRelativeToL - oldAccountSaturationInTranche.satRelativeToL;
            newTrancheSaturation.satInLAssets =
                oldTrancheSaturation.satInLAssets - oldAccountSaturationInTranche.satInLAssets;
        }

        // Use relative saturation for satToLeaf calculation
        uint256 newLeaf = satToLeaf(newTrancheSaturation.satRelativeToL);

        // update both absolute and relative saturation
        tree.trancheToSaturation[int16(tranche)] = newTrancheSaturation;

        if (newTrancheSaturation.satRelativeToL == 0) {
            // case remove tranche from tree

            // remove from old leaf by updating sats and fields
            removeTrancheToLeaf(tree, oldTrancheSaturation, tranche, oldLeaf);

            // we set the new onset to zero since tranche is no longer used, and accrue penalty
            // This is redundant if accruePenalties was already called, but that is not a guarantee.
            calcAndAccrueNewAccountPenalty(tree, oldAccountSaturationInTranche, oldLeaf, account, trancheIndex, 0);
        } else if (newLeaf < oldLeaf) {
            // case change to lower leaf, since we are removing sat
            addSatToTrancheStateUpdatesHigherLeaf(
                tree, tranche, oldTrancheSaturation, newTrancheSaturation, oldLeaf, newLeaf
            );

            // Update account penalty
            // need to keep newPenalty as an intermediate variable, or else stack too deep
            calcAndAccrueNewAccountPenalty(
                tree,
                oldAccountSaturationInTranche,
                oldLeaf,
                account,
                trancheIndex,
                getPenaltySharesPerSatFromLeaf(tree, newLeaf)
            );
        } else {
            // case change to same leaf, oldLeaf == newLeaf, less updating needed

            // decrease leaf sat (both absolute and relative)
            tree.leafs[newLeaf].leafSatPair.satInLAssets -= oldTrancheSaturation.satInLAssets;
            tree.leafs[newLeaf].leafSatPair.satRelativeToL -= oldTrancheSaturation.satRelativeToL;
            unchecked {
                // update sat up the tree (use absolute saturation)
                addSatUpTheTree(tree, -int256(uint256(oldTrancheSaturation.satInLAssets)));
                // penalty offset stays the same
            }
        }
        // case oldLeaf < newLeaf does not exist
    }

    /**
     * @notice  add sat to tree, for each tranche in a loop as needed. we add to each tranche as much as it can bear.
     * @dev     Saturation Distribution Logic
     *
     *          This function distributes debt across multiple tranches, maintaining two types of saturation:
     *          1. satInLAssets: The absolute debt amount in L assets (should remain constant total)
     *          2. satRelativeToL: The relative saturation that depends on the tranche's price level
     *
     *          As we move between tranches (different price levels), the same absolute debt
     *          translates to different relative saturations due to the price-dependent formula.
     *
     *          conceptually satInLAssets should not be scaled as it represents actual debt that
     *          doesn't change with price.
     *
     * @param   tree that is being read from or written to
     * @param   account who's position is being considered
     * @param   trancheDirection direction of sat distribution depending on netX/netY
     * @param   newEndOfLiquidationInTicks the new tranche of the account location in MAG2
     * @param   newSaturation the new sat of the account, in units of LAssets (absolute) and relative to active liquidity
     * @param   activeLiquidityInLAssets of the pair
     * @return  highestSetLeafAdded flag indicating whether we removed sat from the highest leaf xor not
     */
    function addSatToTranche(
        Tree storage tree,
        address account,
        int256 trancheDirection,
        int256 newEndOfLiquidationInTicks,
        SaturationPair memory newSaturation,
        uint256 activeLiquidityInLAssets,
        uint256 userSaturationRatioMAG2
    ) internal returns (bool highestSetLeafAdded) {
        uint256 quarters;
        int256 newTranche;
        {
            uint256 newTrancheMod100 = uint256(
                (0 < newEndOfLiquidationInTicks ? newEndOfLiquidationInTicks : -newEndOfLiquidationInTicks)
                    % TICKS_PER_TRANCHE
            );
            newTranche = newEndOfLiquidationInTicks / TICKS_PER_TRANCHE
                + (newEndOfLiquidationInTicks < 0 && newTrancheMod100 != 0 ? INT_NEGATIVE_ONE : INT_ZERO);
            quarters = newTrancheMod100 == 0 ? NUMBER_OF_QUARTERS : newTrancheMod100 / QUARTER_OF_MAG2;
        }

        if (quarters == 0) {
            // decrease saturation by a factor of B, safe to cast since it makes the value smaller.
            newSaturation.satRelativeToL =
                uint128(Convert.mulDiv(newSaturation.satRelativeToL, Q72, TRANCHE_B_IN_Q72, false));

            // move to next tranche
            newTranche += trancheDirection;

            quarters = NUMBER_OF_QUARTERS;
        }

        tree.accountData[account].lastTranche = int16(newTranche);

        // keep adding sat to tranches as long as more needs adding
        while (0 < newSaturation.satRelativeToL) {
            // if we have reached the edges of price, we are definitely done
            if (MAX_TRANCHE < newTranche || newTranche < MIN_TRANCHE) break;

            // convenience struct to avoid 'stack too deep'
            AddSatToTrancheStateUpdatesStruct memory addSatToTrancheStateUpdatesParams =
            getAddSatToTrancheStateUpdatesParams(
                tree, newTranche, newSaturation, activeLiquidityInLAssets, account, userSaturationRatioMAG2, quarters
            );
            // use all quarters for the next iteration.
            quarters = NUMBER_OF_QUARTERS;

            // if we have nothing to add to this tranche (it is full), move to the next
            if (0 < addSatToTrancheStateUpdatesParams.satAvailableToAdd.satRelativeToL) {
                // update the sat per tranche
                tree.accountData[account].satPairPerTranche.push(
                    SaturationPair({
                        satInLAssets: addSatToTrancheStateUpdatesParams.satAvailableToAdd.satInLAssets,
                        satRelativeToL: addSatToTrancheStateUpdatesParams.satAvailableToAdd.satRelativeToL
                    })
                );

                // update sat, fields and penalties for leafs, parents
                tree.accountData[account].treePenaltyAtOnsetInBorrowLSharesPerSatInQ72PerTranche.push(
                    addSatToTrancheStateUpdates(tree, addSatToTrancheStateUpdatesParams)
                );

                // if we have a new highest leaf, we set this to true so the caller knows the
                // highestSetLeaf needs updating.
                if (tree.highestSetLeaf < addSatToTrancheStateUpdatesParams.newLeaf) {
                    tree.highestSetLeaf = uint16(addSatToTrancheStateUpdatesParams.newLeaf);
                    highestSetLeafAdded = true;
                }
            }

            unchecked {
                // we have less to add for the next tranches
                newSaturation.satRelativeToL -= addSatToTrancheStateUpdatesParams.satAvailableToAdd.satRelativeToL;
                newSaturation.satInLAssets -= addSatToTrancheStateUpdatesParams.satAvailableToAdd.satInLAssets;

                // decrease only relative saturation by a factor of B (absolute debt doesn't change
                // with price) safe to cast since it makes the value smaller.
                newSaturation.satRelativeToL =
                    uint128(Convert.mulDiv(newSaturation.satRelativeToL, Q72, TRANCHE_B_IN_Q72, false));

                // move to next tranche
                newTranche += trancheDirection;
            }
        }

        // account exists in the tree now
        tree.accountData[account].exists = true;
    }

    /**
     * @notice  convenience struct holding the params needed to run `addSatToTrancheStateUpdates`
     * @param   tree that is being read from or written to
     * @param   tranche under consideration
     * @param   newSaturation the saturation values to add
     * @param   activeLiquidityInLAssets of the pair
     * @param   account whos position is being considered
     * @param   userSaturationRatioMAG2 user saturation ratio
     * @param   quarters number of quarters for the calculation
     * @return  addSatToTrancheStateUpdatesParams the struct with required params to
     */
    function getAddSatToTrancheStateUpdatesParams(
        Tree storage tree,
        int256 tranche,
        SaturationPair memory newSaturation,
        uint256 activeLiquidityInLAssets,
        address account,
        uint256 userSaturationRatioMAG2,
        uint256 quarters
    ) internal view returns (AddSatToTrancheStateUpdatesStruct memory addSatToTrancheStateUpdatesParams) {
        SaturationPair memory oldTrancheSaturation = tree.trancheToSaturation[int16(tranche)];

        // calculate how much relative sat can be added
        uint128 satAvailableToAddRelativeToL = calcSatAvailableToAddToTranche(
            activeLiquidityInLAssets,
            newSaturation.satRelativeToL,
            oldTrancheSaturation.satRelativeToL,
            userSaturationRatioMAG2,
            quarters
        );

        // Calculate absolute sat to add based on available space and remaining debt
        uint128 satAvailableToAddInLAssets;
        if (satAvailableToAddRelativeToL == newSaturation.satRelativeToL) {
            // We can add all remaining debt to this tranche
            satAvailableToAddInLAssets = newSaturation.satInLAssets;
        } else {
            // We can only add a portion of the debt to this tranche based on relative saturation
            // limits keeping the percentage of both absolute and relative saturation the same.
            // Safe to cast since we make
            satAvailableToAddInLAssets = SafeCast.toUint128(
                Convert.mulDiv(
                    satAvailableToAddRelativeToL, newSaturation.satInLAssets, newSaturation.satRelativeToL, false
                )
            );
        }

        SaturationPair memory newTrancheSaturation;
        newTrancheSaturation.satInLAssets = oldTrancheSaturation.satInLAssets + satAvailableToAddInLAssets;
        newTrancheSaturation.satRelativeToL = oldTrancheSaturation.satRelativeToL + satAvailableToAddRelativeToL;

        // Use relative saturation for satToLeaf calculation
        uint256 newLeaf = satToLeaf(newTrancheSaturation.satRelativeToL);

        addSatToTrancheStateUpdatesParams = AddSatToTrancheStateUpdatesStruct({
            tranche: tranche,
            newLeaf: newLeaf,
            oldTrancheSaturation: oldTrancheSaturation,
            newTrancheSaturation: newTrancheSaturation,
            satAvailableToAdd: SaturationPair({
                satInLAssets: satAvailableToAddInLAssets,
                satRelativeToL: satAvailableToAddRelativeToL
            }),
            account: account
        });
    }

    /**
     * @notice  depending on old and new leaf of the tranche, update the sats, fields and penalties of the tree
     * @param   tree that is being read from or written to
     * @param   params  convenience struct holding params needed for these updates
     */
    function addSatToTrancheStateUpdates(
        Tree storage tree,
        AddSatToTrancheStateUpdatesStruct memory params
    ) internal returns (uint256) {
        // stack for gas savings
        int256 tranche = params.tranche;
        SaturationPair memory newTrancheSaturation = params.newTrancheSaturation;
        uint256 satAvailableToAddInLAssets = params.satAvailableToAdd.satInLAssets;
        uint256 newLeaf = params.newLeaf;

        // Handle leaf transitions
        uint256 oldLeaf = tree.trancheToLeaf[int16(tranche)];

        // update sat of tranche
        tree.trancheToSaturation[int16(tranche)] = newTrancheSaturation;

        unchecked {
            if (
                oldLeaf == 0
                    && !Uint16Set.exists(tree.leafs[oldLeaf].tranches, uint16(uint256(tranche + MAX_TRANCHE + 1)))
            ) {
                // case tranche does not exist in tree, only add
                addTrancheToLeaf(tree, newTrancheSaturation, tranche, newLeaf);
            } else if (oldLeaf < newLeaf) {
                // case change to higher leaf, since we are adding sat
                addSatToTrancheStateUpdatesHigherLeaf(
                    tree, tranche, params.oldTrancheSaturation, newTrancheSaturation, oldLeaf, newLeaf
                );
            } else {
                // case change to same leaf, oldLeaf == newLeaf, less updating needed
                tree.trancheToLeaf[int16(tranche)] = uint16(newLeaf);

                // increase leaf sat (both absolute and relative)
                tree.leafs[newLeaf].leafSatPair.satInLAssets += params.satAvailableToAdd.satInLAssets;
                tree.leafs[newLeaf].leafSatPair.satRelativeToL += params.satAvailableToAdd.satRelativeToL;

                // update sat up the tree (use absolute saturation)
                addSatUpTheTree(tree, int256(satAvailableToAddInLAssets));
            }
        }

        return getPenaltySharesPerSatFromLeaf(tree, newLeaf);
    }

    /**
     * @notice  Add sat to tranche state updates higher leaf
     * @param   tree that is being read from or written to
     * @param   tranche  the tranche that is being moved
     * @param   oldTrancheSaturation  the old sat of the tranche
     * @param   newTrancheSaturation  the new sat of the tranche
     * @param   oldLeaf  the leaf that the tranche was located in before it was removed
     * @param   newLeaf  the leaf that the tranche was located in after it was removed
     */
    function addSatToTrancheStateUpdatesHigherLeaf(
        Tree storage tree,
        int256 tranche,
        SaturationPair memory oldTrancheSaturation,
        SaturationPair memory newTrancheSaturation,
        uint256 oldLeaf,
        uint256 newLeaf
    ) internal {
        // remove from old leaf by updating sats and fields
        removeTrancheToLeaf(tree, oldTrancheSaturation, tranche, oldLeaf);
        // add to new leaf by updating sats and fields
        addTrancheToLeaf(tree, newTrancheSaturation, tranche, newLeaf);
    }

    /**
     * @notice  removing a tranche from a leaf, update the fields and sats up the tree
     * @param   tree that is being read from or written to
     * @param   trancheSaturation  the saturation of the tranche being moved
     * @param   tranche  that is being moved
     * @param   leaf  the leaf
     */
    function removeTrancheToLeaf(
        Tree storage tree,
        SaturationPair memory trancheSaturation,
        int256 tranche,
        uint256 leaf
    ) internal {
        // set the new leaf of the tranche
        tree.trancheToLeaf[int16(tranche)] = 0;

        unchecked {
            // update the sat of leaf (both absolute and relative)
            tree.leafs[uint16(leaf)].leafSatPair.satInLAssets -= trancheSaturation.satInLAssets;
            tree.leafs[uint16(leaf)].leafSatPair.satRelativeToL -= trancheSaturation.satRelativeToL;

            // update the tranches set of the leaf
            uint256 nodeIndex = leaf / CHILDREN_PER_NODE;
            // unset the fields up the tree
            if (!Uint16Set.remove(tree.leafs[uint16(leaf)].tranches, uint16(uint256(tranche + MAX_TRANCHE + 1)))) {
                setXorUnsetFieldBitUpTheTree(tree, LOWEST_LEVEL_INDEX, nodeIndex, leaf % CHILDREN_PER_NODE, 0);
            }

            // update sat up the tree (use absolute saturation for tree to be used for penalty calculation)
            addSatUpTheTree(tree, -int256(uint256(trancheSaturation.satInLAssets)));
        }
    }

    /**
     * @notice  adding a tranche from a leaf, update the fields and sats up the tree
     * @param   tree that is being read from or written to
     * @param   tranche  that is being moved
     * @param   trancheSaturation  the saturation of the tranche being moved
     * @param   leaf  the leaf
     */
    function addTrancheToLeaf(
        Tree storage tree,
        SaturationPair memory trancheSaturation,
        int256 tranche,
        uint256 leaf
    ) internal {
        unchecked {
            // set the new leaf of the tranche
            tree.trancheToLeaf[int16(tranche)] = uint16(leaf);

            // update the sat of leaf (both absolute and relative)
            tree.leafs[uint16(leaf)].leafSatPair.satInLAssets += trancheSaturation.satInLAssets;
            tree.leafs[uint16(leaf)].leafSatPair.satRelativeToL += trancheSaturation.satRelativeToL;

            // update the tranches set of the leaf
            uint256 nodeIndex = leaf / CHILDREN_PER_NODE;
            // set the fields up the tree
            if (!Uint16Set.insert(tree.leafs[uint16(leaf)].tranches, uint16(uint256(tranche + MAX_TRANCHE + 1)))) {
                setXorUnsetFieldBitUpTheTree(tree, LOWEST_LEVEL_INDEX, nodeIndex, leaf % CHILDREN_PER_NODE, 1);
            }

            // update sat up the tree (use absolute saturation for tree to be used for penalty calculation)
            addSatUpTheTree(tree, int256(uint256(trancheSaturation.satInLAssets)));
        }
    }

    /**
     * @notice  recursively add sat up the tree
     * @param   tree that is being read from or written to
     * @param   satInLAssets  sat to add to the current node, usually uint112, int to allow subtracting sat up the tree
     */
    function addSatUpTheTree(Tree storage tree, int256 satInLAssets) internal {
        tree.totalSatInLAssets = SafeCast.toUint128(uint256(int256(uint256(tree.totalSatInLAssets)) + satInLAssets));
        tree.tranchesWithSaturation = SafeCast.toUint128(
            uint256(int256(tree.tranchesWithSaturation) + (0 < satInLAssets ? INT_ONE : INT_NEGATIVE_ONE))
        );
    }

    // penalty functions

    /**
     * @notice  update penalties in the tree given
     * @param   tree that is being read from or written to
     * @param   thresholdLeaf  from which leaf on the penalty needs to be added inclusive
     * @param   addPenaltyInBorrowLSharesPerSatInQ72  the penalty to be added
     */
    function updatePenalties(
        Tree storage tree,
        uint256 thresholdLeaf,
        uint256 addPenaltyInBorrowLSharesPerSatInQ72
    ) internal {
        uint256 highestLeafPlusOne = tree.highestSetLeaf + 1;
        if (thresholdLeaf < highestLeafPlusOne) {
            for (uint256 leafIndex = thresholdLeaf; leafIndex < highestLeafPlusOne; leafIndex++) {
                tree.leafs[leafIndex].penaltyInBorrowLSharesPerSatInQ72 += addPenaltyInBorrowLSharesPerSatInQ72;
            }
        }
    }

    /**
     * @notice  recursive function to sum penalties from leaf to root
     * @param   tree that is being read from or written to
     * @param   leaf  index (0 based) of the leaf
     * @return  penaltyInBorrowLSharesPerSatInQ72  total penalty at the leaf, non-negative but returned as an int for recursion
     */
    function getPenaltySharesPerSatFromLeaf(
        Tree storage tree,
        uint256 leaf
    ) private view returns (uint256 penaltyInBorrowLSharesPerSatInQ72) {
        return tree.leafs[uint16(leaf)].penaltyInBorrowLSharesPerSatInQ72;
    }

    /**
     * @notice  calc penalty owed by account for repay, total over all the tranches that might contain this accounts' sat
     * @param   tree that is being read from or written to
     * @param   account  who's position is being considered
     * @return  penaltyInBorrowLShares  the penalty owed by the account
     */
    function accrueAccountPenalty(
        Tree storage tree,
        address account
    ) internal returns (uint256 penaltyInBorrowLShares) {
        unchecked {
            // beginning tranche
            int256 tranche = tree.accountData[account].lastTranche;

            // move in the appropriate direction
            int256 trancheDirection = tree.netX ? INT_ONE : -1;

            uint256 satArrayLength = tree.accountData[account].satPairPerTranche.length;
            // add penalty per tranche
            for (uint256 trancheIndex = 0; trancheIndex < satArrayLength; trancheIndex++) {
                // account might have no sat in this tranche
                SaturationPair memory accountSaturationInTranche =
                    tree.accountData[account].satPairPerTranche[trancheIndex];
                if (accountSaturationInTranche.satInLAssets > 0) {
                    // leaf that the tranche belongs to
                    uint256 leaf = tree.trancheToLeaf[int16(tranche)];

                    uint256 penaltyTrancheInBorrowLShares;
                    // calculate penalty for this tranche and update its onset value in the penalties array
                    (
                        penaltyTrancheInBorrowLShares,
                        tree.accountData[account].treePenaltyAtOnsetInBorrowLSharesPerSatInQ72PerTranche[trancheIndex]
                    ) = calcNewAccountPenalty(
                        tree, leaf, accountSaturationInTranche.satInLAssets, account, trancheIndex
                    );
                    penaltyInBorrowLShares += penaltyTrancheInBorrowLShares;
                }
                // next tranche
                tranche += trancheDirection;
            }
        }

        tree.accountData[account].penaltyInBorrowLShares += SafeCast.toUint112(penaltyInBorrowLShares);
    }

    /**
     * @notice  calc penalty owed by account for repay, total over all the tranches that might contain this accounts' sat
     * @param   tree that is being read from or written to
     * @param   leaf  the leaf that the tranche belongs to
     * @param   accountSatInTrancheInLAssets  the sat of the account in the tranche
     * @param   account  who's position is being considered
     * @param   trancheIndex  the index of the tranche that is being added to
     * @return  penaltyInBorrowLShares  the penalty owed by the account
     * @return  accountTreePenaltyInBorrowLSharesPerSatInQ72  the penalty owed by the account in the tranche
     */
    function calcNewAccountPenalty(
        Tree storage tree,
        uint256 leaf,
        uint256 accountSatInTrancheInLAssets,
        address account,
        uint256 trancheIndex
    ) private view returns (uint256 penaltyInBorrowLShares, uint256 accountTreePenaltyInBorrowLSharesPerSatInQ72) {
        // account being moved in the tree => account should take penalty
        accountTreePenaltyInBorrowLSharesPerSatInQ72 = getPenaltySharesPerSatFromLeaf(tree, leaf);
        // round up to assign account more penalty
        penaltyInBorrowLShares = Convert.mulDiv(
            accountTreePenaltyInBorrowLSharesPerSatInQ72
                - tree.accountData[account].treePenaltyAtOnsetInBorrowLSharesPerSatInQ72PerTranche[trancheIndex],
            accountSatInTrancheInLAssets,
            Q72,
            true
        );
    }

    /**
     * @notice  calc and accrue new account penalty
     * @param   tree that is being read from or written to
     * @param   oldAccountSaturationInTranche  the old sat of the account in the tranche
     * @param   oldLeaf  the leaf that the tranche was located in before it was removed
     * @param   account  who's position is being considered
     * @param   trancheIndex  the index of the tranche that is being added to
     * @param   newTreePenaltyAtOnsetInBorrowLSharesPerSatInQ72PerTranche  the new penalty at onset in borrow l shares per sat in q72 per tranche
     */
    function calcAndAccrueNewAccountPenalty(
        Tree storage tree,
        SaturationPair memory oldAccountSaturationInTranche,
        uint256 oldLeaf,
        address account,
        uint256 trancheIndex,
        uint256 newTreePenaltyAtOnsetInBorrowLSharesPerSatInQ72PerTranche
    ) private {
        // we ignore the newTreePenaltyAtOnsetInBorrowLSharesPerSatInQ72PerTranche because we are
        // setting it with the new leaf and accruing the penalty for the old leaf.
        (uint256 penaltyInBorrowLShares,) =
            calcNewAccountPenalty(tree, oldLeaf, oldAccountSaturationInTranche.satInLAssets, account, trancheIndex);

        tree.accountData[account].penaltyInBorrowLShares += SafeCast.toUint112(penaltyInBorrowLShares);
        tree.accountData[account].treePenaltyAtOnsetInBorrowLSharesPerSatInQ72PerTranche[trancheIndex] =
            newTreePenaltyAtOnsetInBorrowLSharesPerSatInQ72PerTranche;
    }

    /**
     * @notice  accrue penalties since last accrual based on all over saturated positions
     *
     * @param   satStruct  main data struct
     * @param   account  who's position is being considered
     * @param   externalLiquidity  Swap liquidity outside this pool
     * @param   duration  since last accrual of penalties
     * @param   allAssetsDepositL  allAsset[DEPOSIT_L]
     * @param   allAssetsBorrowL  allAsset[BORROW_L]
     * @param   allSharesBorrowL  allShares[BORROW_L]
     * @return  penaltyInBorrowLShares  the penalty owed by the account
     * @return  accountPenaltyInBorrowLShares  the penalty owed by the account
     */
    function accruePenalties(
        SaturationStruct storage satStruct,
        address account,
        uint256 externalLiquidity,
        uint256 duration,
        uint256 allAssetsDepositL,
        uint256 allAssetsBorrowL,
        uint256 allSharesBorrowL
    ) internal returns (uint112 penaltyInBorrowLShares, uint112 accountPenaltyInBorrowLShares) {
        if (duration > 0) {
            (
                uint256 penaltyNetXInBorrowLShares,
                uint256 penaltyNetXInBorrowLSharesPerSatInQ72,
                uint256 penaltyNetYInBorrowLShares,
                uint256 penaltyNetYInBorrowLSharesPerSatInQ72,
                uint256 thresholdLeaf
            ) = calcNewPenalties(
                satStruct, externalLiquidity, duration, allAssetsDepositL, allAssetsBorrowL, allSharesBorrowL
            );
            penaltyInBorrowLShares = SafeCast.toUint112(penaltyNetXInBorrowLShares + penaltyNetYInBorrowLShares);

            // update penalties for the tree

            if (penaltyNetXInBorrowLSharesPerSatInQ72 > 0) {
                updatePenalties(satStruct.netXTree, thresholdLeaf, penaltyNetXInBorrowLSharesPerSatInQ72);
            }
            if (penaltyNetYInBorrowLSharesPerSatInQ72 > 0) {
                updatePenalties(satStruct.netYTree, thresholdLeaf, penaltyNetYInBorrowLSharesPerSatInQ72);
            }
        }

        // update penalties for the account

        if (account != ZERO_ADDRESS) {
            accountPenaltyInBorrowLShares = accrueAndRemoveAccountPenalty(satStruct, account);
        }
    }

    /**
     * @notice  calc new penalties
     * @param   satStruct  main data struct
     * @param   externalLiquidity  Swap liquidity outside this pool
     * @param   duration  since last accrual of penalties
     * @param   allAssetsDepositL  allAsset[DEPOSIT_L]
     * @param   allAssetsBorrowL  allAsset[BORROW_L]
     * @param   allSharesBorrowL  allShares[BORROW_L]
     * @return  penaltyNetXInBorrowLShares  the penalty net X in borrow l shares
     * @return  penaltyNetXInBorrowLSharesPerSatInQ72  the penalty net X in borrow l shares per sat in q72
     * @return  penaltyNetYInBorrowLShares  the penalty net Y in borrow l shares
     * @return  penaltyNetYInBorrowLSharesPerSatInQ72  the penalty net Y in borrow l shares per sat in q72
     * @return  thresholdLeaf  the threshold leaf
     */
    function calcNewPenalties(
        SaturationStruct storage satStruct,
        uint256 externalLiquidity,
        uint256 duration,
        uint256 allAssetsDepositL,
        uint256 allAssetsBorrowL,
        uint256 allSharesBorrowL
    )
        private
        view
        returns (
            uint256 penaltyNetXInBorrowLShares,
            uint256 penaltyNetXInBorrowLSharesPerSatInQ72,
            uint256 penaltyNetYInBorrowLShares,
            uint256 penaltyNetYInBorrowLSharesPerSatInQ72,
            uint256 thresholdLeaf
        )
    {
        // calc penalty threshold leaf using external liquidity, active liquidity and saturation penalty ratio.
        thresholdLeaf = satToLeaf(
            (externalLiquidity + allAssetsDepositL - allAssetsBorrowL) * START_SATURATION_PENALTY_RATIO_IN_MAG2 / MAG2
        );

        uint256 currentBorrowUtilizationInWad = Interest.getUtilizationInWads(allAssetsBorrowL, allAssetsDepositL);

        // Calculate saturation percentage using the full satStruct
        uint256 saturationUtilizationInWad = getSatPercentageInWads(satStruct);

        (penaltyNetXInBorrowLShares, penaltyNetXInBorrowLSharesPerSatInQ72) = calcNewPenaltiesGivenTree(
            satStruct.netXTree,
            thresholdLeaf,
            duration,
            currentBorrowUtilizationInWad,
            saturationUtilizationInWad,
            allAssetsDepositL,
            allAssetsBorrowL,
            allSharesBorrowL
        );
        (penaltyNetYInBorrowLShares, penaltyNetYInBorrowLSharesPerSatInQ72) = calcNewPenaltiesGivenTree(
            satStruct.netYTree,
            thresholdLeaf,
            duration,
            currentBorrowUtilizationInWad,
            saturationUtilizationInWad,
            allAssetsDepositL,
            allAssetsBorrowL,
            allSharesBorrowL
        );
    }

    /**
     * @notice  calc new penalties given tree
     * @param   tree that is being read from or written to
     * @param   thresholdLeaf the threshold leaf
     * @param   duration since last accrual of penalties
     * @param   currentBorrowUtilizationInWad current borrow utilization in WAD
     * @param   saturationUtilizationInWad saturation utilization in WAD
     * @param   allAssetsDepositL allAsset[DEPOSIT_L]
     * @param   allAssetsBorrowL allAsset[BORROW_L]
     * @param   allSharesBorrowL allShares[BORROW_L]
     * @return  penaltyInBorrowLShares the penalty net X in borrow l shares
     * @return  penaltyInBorrowLSharesPerSatInQ72 the penalty net X in borrow l shares per sat in q72
     */
    function calcNewPenaltiesGivenTree(
        Tree storage tree,
        uint256 thresholdLeaf,
        uint256 duration,
        uint256 currentBorrowUtilizationInWad,
        uint256 saturationUtilizationInWad,
        uint256 allAssetsDepositL,
        uint256 allAssetsBorrowL,
        uint256 allSharesBorrowL
    ) private view returns (uint256 penaltyInBorrowLShares, uint256 penaltyInBorrowLSharesPerSatInQ72) {
        unchecked {
            // total saturation after thresholdLeaf
            uint128 totalSatLAssetsInPenalty = calcTotalSatAfterLeafInclusive(tree, thresholdLeaf);

            // if no sat over threshold, we are done
            if (totalSatLAssetsInPenalty == 0) return (0, 0);

            // Calculate penalty rate
            uint256 penaltyRatePerSecondInWads = calcSaturationPenaltyRatePerSecondInWads(
                currentBorrowUtilizationInWad, saturationUtilizationInWad, totalSatLAssetsInPenalty, allAssetsDepositL
            );

            uint256 compoundedPenaltyRatePerSecond = Interest.computeInterestAssetsGivenRate(
                duration, totalSatLAssetsInPenalty, allAssetsDepositL, penaltyRatePerSecondInWads
            );

            // Calculate penalty in borrow L assets: totalSat * interestRate * penaltyRate
            uint256 penaltyInBorrowLAssets =
                Convert.mulDiv(totalSatLAssetsInPenalty, compoundedPenaltyRatePerSecond, WAD, false);

            // have accounts owe more (ceil)
            uint256 penaltyInBorrowLAssetsPerSatInQ72 =
                Math.ceilDiv(penaltyInBorrowLAssets * Q72, totalSatLAssetsInPenalty);

            // convert to shares
            penaltyInBorrowLSharesPerSatInQ72 =
                Convert.toShares(penaltyInBorrowLAssetsPerSatInQ72, allAssetsBorrowL, allSharesBorrowL, ROUNDING_UP);

            // recalc the total asset and shares after penalty scaling
            penaltyInBorrowLAssets =
                Convert.mulDiv(penaltyInBorrowLAssetsPerSatInQ72, totalSatLAssetsInPenalty, Q72, false);

            penaltyInBorrowLShares =
                Convert.toShares(penaltyInBorrowLAssets, allAssetsBorrowL, allSharesBorrowL, !ROUNDING_UP);
        }
    }

    /**
     * @notice  accrue and remove account penalty
     * @param   satStruct  main data struct
     * @param   account  who's position is being considered
     * @return  penaltyInBorrowLShares  the penalty owed by the account
     */
    function accrueAndRemoveAccountPenalty(
        SaturationStruct storage satStruct,
        address account
    ) internal returns (uint112 penaltyInBorrowLShares) {
        penaltyInBorrowLShares = SafeCast.toUint112(accrueAccountPenalty(satStruct.netXTree, account))
            + SafeCast.toUint112(accrueAccountPenalty(satStruct.netYTree, account));

        satStruct.netXTree.accountData[account].penaltyInBorrowLShares = 0;
        satStruct.netYTree.accountData[account].penaltyInBorrowLShares = 0;
    }

    /**
     * @notice  calculate the max liquidation premium in bips for a hard liquidation uses the tree *   to determine to allow for partial liquidations as they occur.
     * @dev notice that input params are mutated but then returned to their original state.
     * @param   satStruct  main data struct
     * @param   inputParams  all user assets and prices
     * @param   netBorrowRepaidLAssets  net debt repaid in liquidity assets
     * @param   netDepositSeizedLAssets  net collateral seized in liquidity assets
     * @param   netDebtX  whether net debt is in X or Y
     * @return  maxPremiumInBips  the max premium in bips that
     */
    function calculateHardLiquidationPremium(
        Saturation.SaturationStruct storage satStruct,
        Validation.InputParams memory inputParams,
        address borrower,
        uint256 netBorrowRepaidLAssets,
        uint256 netDepositSeizedLAssets,
        bool netDebtX
    ) internal view returns (uint256 maxPremiumInBips, bool allAssetsSeized) {
        uint256[6] memory oldUserAssets = inputParams.userAssets;
        uint256 netDepositInLAssets =
            mutateInputParamsForPartialLiquidation(satStruct, inputParams, borrower, netBorrowRepaidLAssets, netDebtX);

        maxPremiumInBips = Liquidation.calcHardMaxPremiumInBips(inputParams);

        // if less than 1% is left, we consider it all sized, we don't want liquidators to leave a
        // small amount of collateral to avoid the burning of bad debt.
        allAssetsSeized = netDepositInLAssets * 99 <= netDepositSeizedLAssets * 100;

        inputParams.userAssets = oldUserAssets;
    }

    /**
     * @notice  mutate input params to only include the eligible debt and collateral for ltv
     *   calculation
     * @param   satStruct  main data struct
     * @param   inputParams  all user assets and prices
     * @param   borrower  borrower address
     * @param   netBorrowRepaidLAssets  net debt in liquidity assets
     * @param   netDebtX  whether net debt is in X or Y
     */
    function mutateInputParamsForPartialLiquidation(
        Saturation.SaturationStruct storage satStruct,
        Validation.InputParams memory inputParams,
        address borrower,
        uint256 netBorrowRepaidLAssets,
        bool netDebtX
    ) internal view returns (uint256 netDepositInLAssets) {
        uint256 netDebtInLAssets;
        {
            Validation.CheckLtvParams memory checkLtvParams = Validation.getCheckLtvParams(inputParams);

            (netDebtInLAssets, netDepositInLAssets,) = Validation.calcDebtAndCollateral(checkLtvParams);
        }

        (uint256 partialBorrow, uint256 totalBorrow, uint256 partialDeposit, uint256 totalDeposit) =
            Saturation.calcPortionsForPartialLiquidation(satStruct, borrower, netBorrowRepaidLAssets, netDebtX);
        if (totalBorrow > 0) {
            inputParams.userAssets[BORROW_L] =
                Convert.mulDiv(inputParams.userAssets[BORROW_L], partialBorrow, totalBorrow, false);
            inputParams.userAssets[BORROW_X] =
                Convert.mulDiv(inputParams.userAssets[BORROW_X], partialBorrow, totalBorrow, false);
            inputParams.userAssets[BORROW_Y] =
                Convert.mulDiv(inputParams.userAssets[BORROW_Y], partialBorrow, totalBorrow, false);
        }
        if (totalDeposit > 0) {
            // round in favor of borrower.
            inputParams.userAssets[DEPOSIT_L] =
                Convert.mulDiv(inputParams.userAssets[DEPOSIT_L], partialDeposit, totalDeposit, ROUNDING_UP);
            inputParams.userAssets[DEPOSIT_X] =
                Convert.mulDiv(inputParams.userAssets[DEPOSIT_X], partialDeposit, totalDeposit, ROUNDING_UP);
            inputParams.userAssets[DEPOSIT_Y] =
                Convert.mulDiv(inputParams.userAssets[DEPOSIT_Y], partialDeposit, totalDeposit, ROUNDING_UP);
        }
    }

    /**
     * @notice  Calculate the percent of debt and collateral that is eligible for ltv calculation
     * @dev note that we assume that the min and max sqrt price are switched prior to calling this.
     */
    function calcPortionsForPartialLiquidation(
        Saturation.SaturationStruct storage satStruct,
        address borrower,
        uint256 netBorrowRepaidLAssets,
        bool netDebtX
    )
        internal
        view
        returns (uint256 partialBorrow, uint256 totalBorrow, uint256 partialDeposit, uint256 totalDeposit)
    {
        Account storage account =
            netDebtX ? satStruct.netXTree.accountData[borrower] : satStruct.netYTree.accountData[borrower];
        uint256 trancheCount = account.satPairPerTranche.length;

        // Early return, if there's only one tranche
        if (trancheCount == 1) {
            return (1, 1, 1, 1);
        }

        unchecked {
            uint256 trancheBaseToThePowerOfCount = Q72;

            uint256 partialSatInLAssets = 0;

            for (uint256 i = trancheCount; 0 < i; --i) {
                SaturationPair memory borrowerTranche = account.satPairPerTranche[i - 1];
                uint256 satInRelativeLAssets = borrowerTranche.satRelativeToL;

                partialSatInLAssets += borrowerTranche.satInLAssets;

                // sum across all tranches;
                totalBorrow += Convert.mulDiv(satInRelativeLAssets, Q72, trancheBaseToThePowerOfCount, false);
                totalDeposit += Convert.mulDiv(satInRelativeLAssets, trancheBaseToThePowerOfCount, Q72, false);

                if (partialSatInLAssets < netBorrowRepaidLAssets) {
                    // sum up to the repaid borrow assets.
                    partialBorrow = totalBorrow;
                    partialDeposit = totalDeposit;
                }
                trancheBaseToThePowerOfCount =
                    Convert.mulDiv(trancheBaseToThePowerOfCount, TRANCHE_B_IN_Q72, Q72, false);
            }
        }
    }

    // tree util functions

    /**
     * @notice  recursive function to unset the field when removing a tranche from a leaf
     * @param   tree that is being read from or written to
     * @param   level  level being updated
     * @param   nodeIndex  index is the position (0 based) of the node in its level
     * @param   lowerNodePos  pos is the relative position (0 based) of the node in its parent
     * @param   set  1 for set, 0 for unset
     */
    function setXorUnsetFieldBitUpTheTree(
        Tree storage tree,
        uint256 level,
        uint256 nodeIndex,
        uint256 lowerNodePos,
        uint256 set
    ) internal {
        unchecked {
            // our bit fields store the bits in reverse order of the tree
            uint256 invertedLowerNodePos = CHILDREN_PER_NODE - 1 - lowerNodePos;

            uint256 currentNode = tree.nodes[level][nodeIndex];
            // read the current bit of the node in its field
            uint256 currentBit = readFieldBitFromNode(currentNode, invertedLowerNodePos);
            // if we are unsetting and bit is unset, we are done, since all parents will already be unset
            // if we are setting and bit is set, we are done, since all parents will already be set
            if (currentBit == set) return;

            // flip un-sets the bit since the bit must have been set
            currentNode = writeFlippedFieldBitToNode(currentNode, invertedLowerNodePos);
            // write to currentNode on stack first to save gas
            tree.nodes[level][nodeIndex] = currentNode;

            // if we are at the root, we are done
            if (level == 0) return;

            if (set == 0) {
                // some other child is set, parents can remain set, since we are unsetting
                if (readFieldFromNode(currentNode) != 0) return;
            }

            // nothing else set, unset parents recursively
            setXorUnsetFieldBitUpTheTree(
                tree, level - 1, nodeIndex / CHILDREN_PER_NODE, nodeIndex % CHILDREN_PER_NODE, set
            );
        }
    }

    /**
     * @notice  recursive function to find the highest set leaf starting from a leaf, first upwards, until a set field is found, then downwards to find the best set leaf
     * @param   tree that is being read from or written to
     * @param   level  that we are checking
     * @param   nodeIndex  corresponding to our leaf at our `level`
     * @return  highestSetLeaf highest leaf that is set in the tree
     */
    function findHighestSetLeafUpwards(
        Tree storage tree,
        uint256 level,
        uint256 nodeIndex
    ) private view returns (uint256 highestSetLeaf) {
        unchecked {
            if (readFieldFromNode(tree.nodes[level][nodeIndex]) == 0) {
                if (level == 0) return 0;
                return findHighestSetLeafUpwards(tree, level - 1, nodeIndex / CHILDREN_PER_NODE);
            }
            return findHighestSetLeafDownwards(tree, level, nodeIndex);
        }
    }

    /**
     * @notice  recursive function to find the highest set leaf starting from a node, downwards
     * @dev internal for testing only
     * @param   tree that is being read from or written to
     * @param   level  that we are starting from
     * @param   nodeIndex  that we are starting from
     * @return  leaf highest leaf under the node that is set
     */
    function findHighestSetLeafDownwards(
        Tree storage tree,
        uint256 level,
        uint256 nodeIndex
    ) internal view returns (uint256 leaf) {
        unchecked {
            nodeIndex = CHILDREN_PER_NODE * (nodeIndex + 1) - BitLib.ctz64(tree.nodes[level][nodeIndex]) - 1;

            // if we are at the bottom of the tree, we have found the leaf, which is the node
            if (level == LOWEST_LEVEL_INDEX) return nodeIndex;

            // recurse to the lower level
            return findHighestSetLeafDownwards(tree, level + 1, nodeIndex);
        }
    }

    // liq sqrt price functions

    /**
     * @notice Calc sqrt price at which positions' LTV would reach LTV_MAX
     * @notice Output guarantees $ 0 \le liqSqrtPriceXInQ72 \le uint256(type(uint56).max) << 72 $ (fuzz tested and logic)
     * @notice Outside above range, outputs 0 (essentially no liq)
     * @notice Does not revert if $ LTV_MAX < LTV $, rather $ LTV_MAX < LTV $ causing liq points are returned as 0, as if they do not exist, based on the assumption $ LTV \le LTV_MAX $
     * @param   userAssets  The position
     * @return  netDebtXLiqSqrtPriceXInQ72  0 if no netX liq price exists
     * @return  netDebtYLiqSqrtPriceXInQ72  0 if no netY liq price exists
     */
    function calcLiqSqrtPriceQ72(
        uint256[6] memory userAssets
    ) internal pure returns (uint256 netDebtXLiqSqrtPriceXInQ72, uint256 netDebtYLiqSqrtPriceXInQ72) {
        int256 netLInMAG2;
        int256 netXInMAG2;
        int256 netYInMAG2;
        unchecked {
            netLInMAG2 = int256(userAssets[DEPOSIT_L]) - int256(userAssets[BORROW_L]);
            netXInMAG2 = int256(userAssets[DEPOSIT_X]) - int256(userAssets[BORROW_X]);
            netYInMAG2 = int256(userAssets[DEPOSIT_Y]) - int256(userAssets[BORROW_Y]);
        }

        uint256 netLAbsInMAG2; // uint112
        uint256 netXAbsInMAG2; // uint112
        uint256 netYAbsInMAG2; // uint112

        unchecked {
            // netY*x^2 + netL*x + netX == 0
            // with netY == Y_hat, netL == L_hat * (LTV_MAX/TICKS_PER_TRANCHE + 1), netX == X_hat * LTV_MAX/TICKS_PER_TRANCHE
            // and x is the liq sqrt price in X of Y

            netYInMAG2 *= int256(MAG2); // everything in MAG2 saves some computation later
            netYAbsInMAG2 = uint256(0 <= netYInMAG2 ? netYInMAG2 : -netYInMAG2);

            bool netLPositive = 0 <= netLInMAG2;
            netLAbsInMAG2 = uint256(netLPositive ? netLInMAG2 : -netLInMAG2);
            netLAbsInMAG2 = netLAbsInMAG2 * EXPECTED_SATURATION_LTV_PLUS_ONE_MAG2;
            netLInMAG2 = int256(netLAbsInMAG2);
            if (!netLPositive) netLInMAG2 = -netLInMAG2;

            bool netXPositive = 0 <= netXInMAG2;
            netXAbsInMAG2 = uint256(netXPositive ? netXInMAG2 : -netXInMAG2);
            netXAbsInMAG2 = netXAbsInMAG2 * EXPECTED_SATURATION_LTV_MAG2;
            netXInMAG2 = int256(netXAbsInMAG2);
            if (!netXPositive) netXInMAG2 = -netXInMAG2;
        }

        unchecked {
            if (netYAbsInMAG2 == 0) {
                // Ŷ==0

                // netL != 0 != netX
                // netL xor netX < 0 else under col => 0 <= -netX/netL
                // netL*x+netX=0 <=> x=-netX/netL
                uint256 liqSqrtPriceXInQ72 = Convert.mulDiv(netXAbsInMAG2, Q72, netLAbsInMAG2, false);

                // borrowing L against X
                if (userAssets[BORROW_X] == 0) {
                    netDebtYLiqSqrtPriceXInQ72 = liqSqrtPriceXInQ72;
                }
                // borrowing X against L
                else {
                    netDebtXLiqSqrtPriceXInQ72 = liqSqrtPriceXInQ72;
                }
            }
            // netY != 0
            else if (netXAbsInMAG2 == 0) {
                // X̂==0

                // netL xor netY < 0 else under col => 0 <= -netL/netY and netY*x^2+netL*x=0 <=> x=-netL/netY
                uint256 liqSqrtPriceXInQ72 = Convert.mulDiv(netLAbsInMAG2, Q72, netYAbsInMAG2, false);

                // borrowing L against Y
                if (userAssets[BORROW_Y] == 0) {
                    netDebtXLiqSqrtPriceXInQ72 = liqSqrtPriceXInQ72;
                }
                // borrowing Y against L
                else {
                    netDebtYLiqSqrtPriceXInQ72 = liqSqrtPriceXInQ72;
                }
            }
            // netX != 0
            else if (netLAbsInMAG2 == 0) {
                // L̂==0
                // positionXY == mixed genuinely
                // netX xor netY < 0 else under col => 0 <= -netX/netY and netY*x^2+netX=0 <=> x=sqrt(-netX/netY)

                // 0 < accountLXYInAssets[BORROW_X] && 0 < accountLXYInAssets[BORROW_Y] not possible, assuming good LTV

                if (0 < userAssets[DEPOSIT_X]) {
                    if (0 < userAssets[DEPOSIT_Y]) return (0, 0);
                } // no solution

                uint256 liqSqrtPriceXInQ72 = Math.sqrt(Convert.mulDiv(netXAbsInMAG2, Q144, netYAbsInMAG2, false));

                // borrowing Y against X
                if (0 < userAssets[DEPOSIT_X]) {
                    netDebtYLiqSqrtPriceXInQ72 = liqSqrtPriceXInQ72;
                }
                // borrowing X against Y
                else {
                    netDebtXLiqSqrtPriceXInQ72 = liqSqrtPriceXInQ72;
                }
            } else {
                // netY != 0 && netL != 0 && netX != 0

                (netDebtXLiqSqrtPriceXInQ72, netDebtYLiqSqrtPriceXInQ72) = calcLiqSqrtPriceQ72HandleAllABCNonZero(
                    CalcLiqSqrtPriceHandleAllABCNonZeroStruct(
                        netLInMAG2, netXInMAG2, netYInMAG2, netYAbsInMAG2, userAssets[BORROW_X], userAssets[BORROW_Y]
                    )
                );
            }

            // bounding

            if (
                netDebtXLiqSqrtPriceXInQ72 < TickMath.MIN_SQRT_PRICE_IN_Q72
                    || TickMath.MAX_SQRT_PRICE_IN_Q72 < netDebtXLiqSqrtPriceXInQ72
            ) {
                netDebtXLiqSqrtPriceXInQ72 = 0;
            }
            if (
                netDebtYLiqSqrtPriceXInQ72 < TickMath.MIN_SQRT_PRICE_IN_Q72
                    || TickMath.MAX_SQRT_PRICE_IN_Q72 < netDebtYLiqSqrtPriceXInQ72
            ) {
                netDebtYLiqSqrtPriceXInQ72 = 0;
            }

            // netX needs division by LTV_MAX
            if (0 < netDebtXLiqSqrtPriceXInQ72) {
                netDebtXLiqSqrtPriceXInQ72 =
                    Convert.mulDiv(netDebtXLiqSqrtPriceXInQ72, MAG2, EXPECTED_SATURATION_LTV_MAG2, false);
            }
        }
    }

    /**
     * @notice  calc liq price when the quadratic has all 3 terms, netY,netL,netX, i.e. X, Y, L are all significant
     * @param   input the position
     * @return  netDebtXLiqSqrtPriceXInQ72 0 if no netX liq price exists
     * @return  netDebtYLiqSqrtPriceXInQ72 0 if no netY liq price exists
     */
    function calcLiqSqrtPriceQ72HandleAllABCNonZero(
        CalcLiqSqrtPriceHandleAllABCNonZeroStruct memory input
    ) internal pure returns (uint256 netDebtXLiqSqrtPriceXInQ72, uint256 netDebtYLiqSqrtPriceXInQ72) {
        int256 numeratorPlusInMAG2;
        int256 numeratorMinusInMAG2;
        unchecked {
            // stack for gas savings
            int256 netLInMAG2 = input.netLInMAG2;

            // calc radical == netL^2 - 4*netY*netX
            int256 radicalInMAG2 = netLInMAG2 * netLInMAG2 - 4 * input.netYInMAG2 * input.netXInMAG2;
            if (radicalInMAG2 < 0) return (0, 0);

            // netL^2=4*netY*netX <=> x=-netL/2/netY => !MixedXY
            // !AllB, else would violate LTV
            // AllD, which has no liq point, except a single point where we cannot be, else bad LTV
            if (radicalInMAG2 == 0) return (0, 0);

            // 0 < radical

            int256 sqrtRadicalInMAG2 = int256(Math.sqrt(uint256(radicalInMAG2)));
            numeratorPlusInMAG2 = netLInMAG2 + sqrtRadicalInMAG2;
            numeratorMinusInMAG2 = netLInMAG2 - sqrtRadicalInMAG2;
        }

        // stack for gas savings
        uint256 netYAbsInMAG2 = input.netYAbsInMAG2;

        // calc solution fraction
        uint256 liqSqrtPriceXPlusInQ72;
        uint256 liqSqrtPriceXMinusInQ72;
        unchecked {
            uint256 numeratorMinusAbsInMAG2 =
                uint256(numeratorMinusInMAG2 < 0 ? -numeratorMinusInMAG2 : numeratorMinusInMAG2);
            liqSqrtPriceXPlusInQ72 = Convert.mulDiv(
                uint256(numeratorPlusInMAG2 < 0 ? -numeratorPlusInMAG2 : numeratorPlusInMAG2),
                Q72,
                2 * netYAbsInMAG2,
                false
            );
            liqSqrtPriceXMinusInQ72 = Convert.mulDiv(numeratorMinusAbsInMAG2, Q72, 2 * netYAbsInMAG2, false);
        }

        if (input.borrowedXAssets == 0) {
            if (input.borrowedYAssets == 0) {
                // AllD => good LTV outside range
                netDebtYLiqSqrtPriceXInQ72 = liqSqrtPriceXPlusInQ72;
                netDebtXLiqSqrtPriceXInQ72 = liqSqrtPriceXMinusInQ72;
            } else {
                // YB != 0
                // XY mixed, XD != 0
                netDebtYLiqSqrtPriceXInQ72 = liqSqrtPriceXPlusInQ72;
            }
        } else {
            // XB != 0
            // if (accountLXYInAssets[BORROW_Y] == 0) {
            if (input.borrowedYAssets == 0) {
                // XY mixed, YD != 0
                netDebtXLiqSqrtPriceXInQ72 = liqSqrtPriceXMinusInQ72;
            } else {
                // AllB => good LTV inside range
                netDebtYLiqSqrtPriceXInQ72 = liqSqrtPriceXPlusInQ72;
                netDebtXLiqSqrtPriceXInQ72 = liqSqrtPriceXMinusInQ72;
            }
        }
    }

    // sat functions

    /**
     * @notice Calculate the ratio by which the saturation has changed for `account`.
     * @param satStruct The saturation struct containing both netX and netY trees.
     * @param inputParams The params containing the position of `account`.
     * @param liqSqrtPriceInXInQ72 The liquidation price for netX.
     * @param liqSqrtPriceInYInQ72 The liquidation price for netY.
     * @param account The account for which we are calculating the saturation change ratio.
     * @return ratioNetXBips The ratio representing the change in netX saturation for account.
     * @return ratioNetYBips The ratio representing the change in netY saturation for account.
     */
    function calcSatChangeRatioBips(
        SaturationStruct storage satStruct,
        Validation.InputParams memory inputParams,
        uint256 liqSqrtPriceInXInQ72,
        uint256 liqSqrtPriceInYInQ72,
        address account,
        uint256 desiredSaturationMAG2
    ) internal view returns (uint256 ratioNetXBips, uint256 ratioNetYBips) {
        // Calculate ratios for netX tree only if netX liquidation price exists
        if (0 < liqSqrtPriceInXInQ72) {
            (, SaturationPair memory newSaturation) =
                calcLastTrancheAndSaturation(inputParams, liqSqrtPriceInXInQ72, desiredSaturationMAG2, true);
            uint256 oldSatInNetXTreeInLAssets;

            uint256 satArrayLength = satStruct.netXTree.accountData[account].satPairPerTranche.length;
            for (uint256 i; newSaturation.satRelativeToL > 0 && i < satArrayLength; i++) {
                // we can only saturate the next tranche if it has some saturation
                uint128 nextTrancheSaturation = uint128(
                    Math.min(
                        satStruct.netXTree.accountData[account].satPairPerTranche[i].satRelativeToL,
                        newSaturation.satRelativeToL
                    )
                );

                newSaturation.satRelativeToL -= nextTrancheSaturation;
                oldSatInNetXTreeInLAssets += nextTrancheSaturation;

                // scale saturation for the next tranche, safe to cast since we are scaling down.
                newSaturation.satRelativeToL =
                    uint128(Convert.mulDiv(newSaturation.satRelativeToL, Q72, TRANCHE_B_IN_Q72, false));
            }
            if (newSaturation.satRelativeToL > 0) {
                ratioNetXBips = Math.ceilDiv(
                    (newSaturation.satRelativeToL + oldSatInNetXTreeInLAssets) * SOFT_LIQUIDATION_SCALER,
                    oldSatInNetXTreeInLAssets
                );
            }
        }

        // Calculate ratios for netY tree only if netY liquidation price exists
        if (0 < liqSqrtPriceInYInQ72) {
            (, SaturationPair memory newSaturation) =
                calcLastTrancheAndSaturation(inputParams, liqSqrtPriceInYInQ72, desiredSaturationMAG2, false);

            uint256 oldSatInNetYTreeInLAssets;
            uint256 satArrayLength = satStruct.netYTree.accountData[account].satPairPerTranche.length;

            for (uint256 i; newSaturation.satRelativeToL > 0 && i < satArrayLength; i++) {
                // we can only saturate the next tranche if it has some saturation
                uint128 nextTrancheSaturation = uint128(
                    Math.min(
                        satStruct.netYTree.accountData[account].satPairPerTranche[i].satRelativeToL,
                        newSaturation.satRelativeToL
                    )
                );

                newSaturation.satRelativeToL -= nextTrancheSaturation;
                oldSatInNetYTreeInLAssets += nextTrancheSaturation;

                // scale saturation for the next tranche, safe to cast since we are scaling down.
                newSaturation.satRelativeToL =
                    uint128(Convert.mulDiv(newSaturation.satRelativeToL, Q72, TRANCHE_B_IN_Q72, false));
            }
            if (newSaturation.satRelativeToL > 0) {
                ratioNetYBips = Math.ceilDiv(
                    (newSaturation.satRelativeToL + oldSatInNetYTreeInLAssets) * SOFT_LIQUIDATION_SCALER,
                    oldSatInNetYTreeInLAssets
                );
            }
        }
    }

    /**
     * @notice  calc total sat of all accounts/tranches/leafs higher (and same) as the threshold
     * @dev     iterate through leaves directly since penalty range is fixed (~8 leaves from 85% to 95% sat)
     * @param   tree that is being read from or written to
     * @param   thresholdLeaf leaf to start adding sat from
     * @return  satInLAssetsInPenalty total sat of all accounts with tranche in a leaf from at least `thresholdLeaf` (absolute saturation)
     */
    function calcTotalSatAfterLeafInclusive(
        Tree storage tree,
        uint256 thresholdLeaf
    ) internal view returns (uint128 satInLAssetsInPenalty) {
        uint256 maxLeaf = tree.highestSetLeaf;
        if (thresholdLeaf > maxLeaf) {
            return 0; // No leaves in penalty range
        }

        for (uint256 leafIndex = thresholdLeaf; leafIndex <= maxLeaf; leafIndex++) {
            // Add absolute saturation stored in each leaf
            uint128 leafSat = tree.leafs[leafIndex].leafSatPair.satInLAssets;
            satInLAssetsInPenalty += leafSat;
        }
    }

    /**
     * @notice  Get precalculated saturation percentage for a given delta (maxLeaf - highestLeaf)
     * @param   satStruct  The saturation struct
     * @return  saturationPercentage  The precalculated saturation percentage as uint256
     */
    function getSatPercentageInWads(
        SaturationStruct storage satStruct
    ) internal view returns (uint256 saturationPercentage) {
        uint16 highestLeaf = uint16(Math.max(satStruct.netXTree.highestSetLeaf, satStruct.netYTree.highestSetLeaf));
        if (satStruct.maxLeaf == 0 && highestLeaf == 0) {
            return 0;
        }
        uint16 delta = satStruct.maxLeaf - highestLeaf;
        if (delta > 8) {
            return 0;
        }

        assembly {
            switch delta
            case 4 { saturationPercentage := SAT_PERCENTAGE_DELTA_4_WAD }
            case 5 { saturationPercentage := SAT_PERCENTAGE_DELTA_5_WAD }
            case 6 { saturationPercentage := SAT_PERCENTAGE_DELTA_6_WAD }
            case 7 { saturationPercentage := SAT_PERCENTAGE_DELTA_7_WAD }
            case 8 { saturationPercentage := SAT_PERCENTAGE_DELTA_8_WAD }
            default { saturationPercentage := SAT_PERCENTAGE_DELTA_DEFAULT_WAD } // return 95% by default
        }
    }

    /**
     * @notice  convert sat to leaf
     * @param   satLAssets sat to convert
     * @return  leaf  resulting leaf from 0 to 2**12-1
     */
    function satToLeaf(
        uint256 satLAssets
    ) internal pure returns (uint256 leaf) {
        // handle edge cases
        if (satLAssets >= MIN_LIQ_TO_REACH_PENALTY) {
            if (satLAssets >= LOWEST_POSSIBLE_IN_PENALTY) return LEAFS - 1;
            // Q112 to ensure our max value of our desired range is within the range of the function.
            uint256 satInQ112 = satLAssets * Q112;
            // the smaller Q number means some of our values are less than 0, so we correct all values to be positive by adding TICK_OFFSET (1112).
            int16 tick = TickMath.getTickAtPrice(satInQ112) + TICK_OFFSET;
            // multiply by 2 since `getTickAtPrice` does a square root on the value before taking the log. Then we change the base and shift to our desired domain.
            leaf = (2 * uint256(int256(tick)) * Q128 + SAT_CHANGE_OF_BASE_TIMES_SHIFT) / SAT_CHANGE_OF_BASE_Q128;
        }
    }

    /**
     * @notice  calc how much sat can be added to a tranche such that it is healthy
     * @param   activeLiquidityInLAssets  of the pair
     * @param   targetSatToAddInLAssets  the sat that we want to add
     * @param   currentTrancheSatInLAssets  the sat that the tranche already hols
     * @return  satAvailableToAddInLAssets  considering the `currentTrancheSatInLAssets` and the max a tranche can have
     */
    function calcSatAvailableToAddToTranche(
        uint256 activeLiquidityInLAssets,
        uint128 targetSatToAddInLAssets,
        uint128 currentTrancheSatInLAssets,
        uint256 userSaturationRatioMAG2,
        uint256 quarters
    ) internal pure returns (uint128 satAvailableToAddInLAssets) {
        activeLiquidityInLAssets = Convert.mulDiv(activeLiquidityInLAssets, userSaturationRatioMAG2, MAG2, false);

        // how much sat can be added to the tranche
        uint256 maxSatAvailableInTranche;
        if (currentTrancheSatInLAssets < activeLiquidityInLAssets) {
            maxSatAvailableInTranche = activeLiquidityInLAssets - currentTrancheSatInLAssets;
        }

        // we will add as much as we want to add, at most as much is possible to add
        // Safe to cast since we are taking the min of a 128 and an amount smaller than the
        // difference between tow 128 numbers since active liquidity assets is max 128.
        unchecked {
            satAvailableToAddInLAssets =
                uint128(Math.min(targetSatToAddInLAssets, Convert.mulDiv(maxSatAvailableInTranche, quarters, 4, false)));
        }
    }

    /**
     * @notice  calc the tranche percent and the saturation of the tranche
     * @param   inputParams  the input params
     * @param   liqSqrtPriceInXInQ72  the liq sqrt price in X
     * @param   desiredThresholdMag2  the desired threshold
     * @param   netDebtX  whether the net debt is X or Y
     * @return  endOfLiquidationInTicks  the point at which the liquidation would end.
     * @return  saturation the saturation of the tranche
     */
    function calcLastTrancheAndSaturation(
        Validation.InputParams memory inputParams,
        uint256 liqSqrtPriceInXInQ72,
        uint256 desiredThresholdMag2,
        bool netDebtX
    ) internal pure returns (int256 endOfLiquidationInTicks, SaturationPair memory saturation) {
        (uint256 netDebtXorYAssets, uint256 tempSatInLAssets, uint256 trancheSpanInTicks) =
            calculateNetDebtAndSpan(inputParams, desiredThresholdMag2, netDebtX);
        saturation.satInLAssets = SafeCast.toUint128(tempSatInLAssets);
        int256 bestCaseStartOfLiquidation = trancheSpanInTicks > QUARTER_MINUS_ONE
            ? calcTrancheAtStartOfLiquidation(
                netDebtXorYAssets, inputParams.activeLiquidityAssets, trancheSpanInTicks, desiredThresholdMag2, netDebtX
            )
            : TickMath.getTickAtPrice(liqSqrtPriceInXInQ72 ** 2 / Q16);

        int256 trancheSpanDirectionInTicks = (netDebtX ? INT_NEGATIVE_ONE : INT_ONE) * int256(trancheSpanInTicks);

        endOfLiquidationInTicks = bestCaseStartOfLiquidation + trancheSpanDirectionInTicks;

        uint256 startSqrtPrice = TickMath.getSqrtPriceAtTick(int16(bestCaseStartOfLiquidation));

        // Calculate relative saturation
        saturation.satRelativeToL =
            SafeCast.toUint128(calculateSaturation(netDebtXorYAssets, startSqrtPrice, trancheSpanInTicks, netDebtX));
    }

    /**
     * @notice  calc net debt and span
     * @param   inputParams  the input params
     * @param   desiredThresholdMag2  the desired threshold
     * @param   netDebtX  whether the net debt is X or Y
     * @return  netDebtXorYAssets  the net debt
     * @return  netDebtLAssets  the net debt in L assets
     * @return  trancheSpanInTicks  the tranche span percentage
     */
    function calculateNetDebtAndSpan(
        Validation.InputParams memory inputParams,
        uint256 desiredThresholdMag2,
        bool netDebtX
    ) internal pure returns (uint256 netDebtXorYAssets, uint256 netDebtLAssets, uint256 trancheSpanInTicks) {
        Validation.CheckLtvParams memory checkLtvParams = Validation.getCheckLtvParams(inputParams);
        uint256 netCollateralLAssets;
        (netDebtLAssets, netCollateralLAssets,) = Validation.calcDebtAndCollateral(checkLtvParams);

        trancheSpanInTicks = calcMinTrancheSpanInTicks(
            netDebtLAssets, netCollateralLAssets, inputParams.activeLiquidityAssets, desiredThresholdMag2
        );

        // Convert to assets of X or Y so that `calcTrancheAtStartOfLiquidation` &
        // `calculateSaturation` does not need to convert from L to X or Y.
        netDebtXorYAssets = netDebtX
            ? Validation.convertLToX(
                netDebtLAssets, inputParams.sqrtPriceMinInQ72, inputParams.activeLiquidityScalerInQ72, false
            )
            : Validation.convertLToY(
                netDebtLAssets, inputParams.sqrtPriceMaxInQ72, inputParams.activeLiquidityScalerInQ72, false
            );
    }

    /**
     * @notice  calculate the relative saturation of the position at the end of liquidation.
     * @dev Since we place saturation in tranches starting at the end and moving forward, this
     *   calculates the entire saturation as if it would fit in the last tranche, we then need to
     *   adjust the saturation each time we move to the next tranche by dividing by a factor of
     *   $$B$$. The equation here is slightly different than the equation in our description since
     *   we multiply by a factor of $$B$$ for each tranche we move back away from the start.
     *   thus here we use, where $$TCount$$ is the number of tranches we need to move back,
     *   ```math
     *    \begin{equation}
     *      saturationRelativeToL =
     *        \begin{cases}
     *          \frac{debtX}{B^{T_{1}}}\left(\frac{B^{TCount}}{B-1}\right) \\
     *          debtY\cdot B^{T_{0}}\cdot\left(\frac{B^{TCount}}{B-1}\right)
     *        \end{cases}
     *    \end{equation}
     *   ```
     *   As we iterate through tranches, we divide by a factor of $$B$$ such that when we reach the
     *   final tranche, our equation from the start applies.
     *
     * @param  netDebtXOrYAssets  the net debt in X or Y assets.
     * @param  startSqrtPriceQ72  the sqrt price at the start of liquidation
     * @param  trancheSpanInTicks  the span of the tranche in ticks.
     * @param  netDebtX  whether the debt is in X or Y assets
     * @return saturation  the saturation relative to active liquidity assets.
     */
    function calculateSaturation(
        uint256 netDebtXOrYAssets,
        uint256 startSqrtPriceQ72,
        uint256 trancheSpanInTicks,
        bool netDebtX
    ) internal pure returns (uint256 saturation) {
        uint256 baseToPowerOfCountQ72 = Q72;
        uint256 quarters = Math.max(trancheSpanInTicks / QUARTER_OF_MAG2, 1);
        for (uint256 i = 0; i < quarters;) {
            baseToPowerOfCountQ72 = Convert.mulDiv(baseToPowerOfCountQ72, TRANCHE_QUARTER_B_IN_Q72, Q72, false);
            unchecked {
                i++;
            }
        }

        // we use the sqrtPrice associated with the start of liquidation point instead of the
        // exchange rate due to our equation for saturation being defined in those terms.
        // We reuses convert functions that are purposed for converting to LAssets, even though
        // that is not what we are calculating here.
        saturation = (
            netDebtX
                ? Validation.convertXToL(netDebtXOrYAssets, startSqrtPriceQ72, Q72, true)
                : Validation.convertYToL(netDebtXOrYAssets, startSqrtPriceQ72, Q72, true)
        );

        // apply normalization factors
        saturation = Convert.mulDiv(
            Math.ceilDiv(saturation * baseToPowerOfCountQ72, TRANCHE_B_IN_Q72 - Q72),
            SATURATION_TIME_BUFFER_IN_MAG2,
            MAG2,
            false
        );
    }

    /**
     * @notice  calc the minimum tranche count given the collateral, debt, active liquidity and desired threshold
     * @param   collateral  the collateral amount
     * @param   debt  the debt amount
     * @param   activeLiquidityAssets  the active liquidity assets
     * @param   desiredThresholdMag2  the desired threshold
     * @return  trancheSpanInTicks  the tranche span a position will need. When greater
     *          than TICKS_PER_TRANCHE, multiple tranches are needed.
     */
    function calcMinTrancheSpanInTicks(
        uint256 collateral,
        uint256 debt,
        uint256 activeLiquidityAssets,
        uint256 desiredThresholdMag2
    ) internal pure returns (uint256 trancheSpanInTicks) {
        uint256 bQ64 =
        // debt and collateral are 256 bits together, so we have to divide
        // by MAG6 before multiplying by collateral to avoid overflow on multiplication.
        Convert.mulDiv(
            Convert.mulDiv(
                Convert.mulDiv(debt, EXPECTED_SATURATION_LTV_MAG2_TIMES_SAT_BUFFER_SQUARED, MAG6, false),
                collateral,
                // divide active liquidity in two steps to avoid the result vanishing.
                activeLiquidityAssets * desiredThresholdMag2 ** 2,
                false
            ),
            // scale to Q64 and multiply by Mag4 to cancel Mag4 from last division Mag4 units.
            MAG4_TIMES_Q64,
            // divide by by the second active liquidity asset.
            activeLiquidityAssets,
            false
        ) + TWO_Q64;

        // apply quadratic formula, a and c are both 1.
        uint256 inputQ64 = (bQ64 + Math.sqrt(bQ64 ** 2 - FOUR_Q128)) / 2;

        // we want the tick rounded up, and since the function rounds down, we
        // multiply by B_Q72 - 1. This is more accurate than adding 1 after the function.
        int16 tick = TickMath.getTickAtPrice(Convert.mulDiv(inputQ64 ** 2, B_Q72_MINUS_ONE, Q72, false));

        trancheSpanInTicks = uint256(tick == int16(0) ? INT_ONE : tick);
    }

    /**
     * @notice  calc the tranche at start of liquidation
     * @param   netDebtXorYAssets  the net debt in X or Y assets.
     * @param   activeLiquidityAssets  the active liquidity assets
     * @param   trancheSpanInTicks  the tranche span percentage
     * @param   desiredThresholdMag2  the desired threshold
     * @param   netDebtX  whether the net debt is X or Y
     * @return  trancheStartOfLiquidationMag2  the tranche at start of liquidation
     */
    function calcTrancheAtStartOfLiquidation(
        uint256 netDebtXorYAssets,
        uint256 activeLiquidityAssets,
        uint256 trancheSpanInTicks,
        uint256 desiredThresholdMag2,
        bool netDebtX
    ) internal pure returns (int256 trancheStartOfLiquidationMag2) {
        int16 direction;
        uint256 inputQ64;

        uint256 baseToPowerOfCount = Q72;
        {
            uint256 quarters = trancheSpanInTicks / QUARTER_OF_MAG2;
            for (uint256 i = 0; i < quarters;) {
                baseToPowerOfCount = Convert.mulDiv(baseToPowerOfCount, TRANCHE_QUARTER_B_IN_Q72, Q72, false);
                unchecked {
                    i++;
                }
            }

            unchecked {
                inputQ64 =
                // top is uint128 * MAG2 * Q6.72 which fits in 211, we add 32 before dividing, then
                // add another 32 to make it a Q64 number. bottom is same. round down.
                Convert.mulDiv(
                    netDebtXorYAssets * SATURATION_TIME_BUFFER_IN_MAG2,
                    baseToPowerOfCount * Q32,
                    (baseToPowerOfCount - Q72) * activeLiquidityAssets * desiredThresholdMag2,
                    false
                ) * Q32;
            }

            direction = int16(netDebtX ? INT_ONE : INT_NEGATIVE_ONE);
        }

        int256 tick = TickMath.getTickAtPrice(inputQ64 ** 2);
        int256 correct = (tick < -1) || (tick < 1 && !netDebtX) ? direction : INT_ZERO;

        trancheStartOfLiquidationMag2 = tick * direction + correct;
    }

    // bit functions
    // node read write
    // uint node = [112 empty bits, 16 tranche count bits, 112 sat bits, 16 field bits]

    /**
     * @notice  read single bit value from the field of a node
     * @param   node  the full node
     * @param   bitPos  position of the bit $ \le 16 $
     * @return  bit  the resulting bit, 0 xor 1, as a uint
     */
    function readFieldBitFromNode(uint256 node, uint256 bitPos) internal pure returns (uint256 bit) {
        uint256 MASK = 1 << bitPos;
        assembly ("memory-safe") {
            bit := iszero(iszero(and(node, MASK)))
        }
    }

    /**
     * @notice  write to node
     * @param   nodeIn  node to read from
     * @param   bitPos  position of the bit $ \le 16 $
     * @return  nodeOut  node with bit flipped
     */
    function writeFlippedFieldBitToNode(uint256 nodeIn, uint256 bitPos) internal pure returns (uint256 nodeOut) {
        uint256 MASK = 1 << bitPos;
        nodeOut = nodeIn ^ MASK;
    }

    /**
     * @notice  read field from node
     * @param   node  node to read from
     * @return  field  field of the node
     */
    function readFieldFromNode(
        uint256 node
    ) internal pure returns (uint256 field) {
        field = node & FIELD_NODE_MASK;
    }

    /**
     * @notice Calculates the penalty scaling factor based on current borrow utilization and saturation
     * @dev This implements the penalty rate function
     *      Formula: ((1 - u_0) * f_interestPerSecond(u_1) * allAssetsDepositL) / (WAD * satInLAssetsInPenalty)
     *      Where u_1 = (0.90 - (1 - u_0) * (0.95 - u_s) / 0.95)
     * @param currentBorrowUtilizationInWad Current borrow utilization of L (u_0)
     * @param saturationUtilizationInWad Current saturation utilization (u_s)
     * @param satInLAssetsInPenalty The saturation in L assets in the penalty
     * @param allAssetsDepositL The total assets deposited in L
     * @return penaltyRatePerSecondInWads The penalty rate per second in WADs
     */
    function calcSaturationPenaltyRatePerSecondInWads(
        uint256 currentBorrowUtilizationInWad,
        uint256 saturationUtilizationInWad,
        uint128 satInLAssetsInPenalty,
        uint256 allAssetsDepositL
    ) internal pure returns (uint256 penaltyRatePerSecondInWads) {
        // Calculate target utilization: u_1 = 0.90 - (1 - u_0) * (0.95 - u_s) / 0.95
        uint256 oneMinusCurrentUtilizationWads = WAD - currentBorrowUtilizationInWad;

        uint256 saturationBufferWads = MAX_SATURATION_PERCENT_IN_WAD - saturationUtilizationInWad;

        uint256 targetUtilizationComponentWads =
            Convert.mulDiv(oneMinusCurrentUtilizationWads, saturationBufferWads, MAX_SATURATION_PERCENT_IN_WAD, false);

        uint256 targetUtilizationInWads;
        if (targetUtilizationComponentWads > MAX_UTILIZATION_PERCENT_IN_WAD) {
            // in this case we have low borrow utilization and low saturation, so we can return 0 for min penalty scaling factor
            targetUtilizationInWads = 0;
        } else {
            // Normal case: u_1 = 0.90 - component
            targetUtilizationInWads = MAX_UTILIZATION_PERCENT_IN_WAD - targetUtilizationComponentWads;
        }

        // f_interestPerSecond(u_1) | Get the interest rate at target utilization (this is already magnified by 5x for liquidity)
        uint256 interestRateAtTargetUtilizationInWads = Interest.getAnnualInterestRatePerSecondInWads(
            targetUtilizationInWads
        ) * LIQUIDITY_INTEREST_RATE_MAGNIFICATION;

        // penaltyRatePerSecondInWads = ((1 - u_0) * f_interestPerSecond(u_1) * allAssetsDepositL) / WAD * satInLAssetsInPenalty
        uint256 liquidityProviderRateInWads =
            Convert.mulDiv(oneMinusCurrentUtilizationWads, interestRateAtTargetUtilizationInWads, WAD, false);
        penaltyRatePerSecondInWads =
            Convert.mulDiv(liquidityProviderRateInWads, allAssetsDepositL, satInLAssetsInPenalty, false);
    }
}
