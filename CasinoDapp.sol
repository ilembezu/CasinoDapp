pragma solidity ^0.5.2;

contract CasinoDapp {

  // There is minimum and maximum bets.
  // min bet 0.5 tomo
  // max bet 30000 tomo
  uint constant MIN_BET = 0.5 ether;
  uint constant MAX_AMOUNT = 30000 ether;

  // Modulo is a number of equiprobable outcomes in a game:
  // 4 for suit
  // 13 for size
  // 13 for number
  uint constant MAX_MODULO = 216;

  // For modulos below this threshold rolls are checked against a bit mask,
  // thus allowing betting on any combination of outcomes. For example, given
  // modulo 13 for suit, 0000000111111 mask (base-2, big endian) means betting on
  // card A,2,3,4,5,6; for games with modulos higher than threshold, a simple
  // limit is used, allowing betting on any outcome in [0, N) range.

  // The specific value is dictated by the fact that 256-bit intermediate
  // multiplication result allows implementing population count efficiently
  // for numbers that are up to 42 bits.
  uint constant MAX_MASK_MODULO = 216;

  // check on bet mask overflow.
  uint constant MAX_BET_MASK = 2 ** MAX_MASK_MODULO;

  // EVM BLOCKHASH opcode can query no further than 256 blocks into the
  // past. Given that settleBet uses block hash of placeBet as one of
  // complementary entropy sources, we cannot process bets older than this
  // threshold. On rare occasions croupier/operator may fail to invoke
  // settleBet in this timespan due to technical issues
  // such bets can be refunded via invoking refundBet.
  uint constant BET_EXPIRATION_BLOCKS = 250;

  // jackpot
  // Bets lower than this amount do not participate in jackpot rolls
  // and JACKPOT_FEE will not be deduced
  // 3 tomo
  uint public constant MIN_JACKPOT_BET = 3 ether;
  // Chance to win jackpot (currently 0.1%)
  uint public constant JACKPOT_MODULO = 1000;
  // jackpot fee deducted into jackpot fund.
  // 0.01 tomo as jackpot fee
  uint public constant JACKPOT_FEE = 0.05 ether;

  // Contract ownership
  address payable public owner1;
  address payable public owner2;

  // Adjustable max bet profit. Used to cap bets against dynamic odds.
  uint128 public maxProfit;

  bool public killed;

  // The address corresponding to a private key used to sign placeBet commits.
  address public secretSigner;

  // Croupier address
  address public croupier;

  // Accumulated jackpot fund.
  uint128 public jackpotSize;

  // Funds that are locked in potentially winning bets. Prevents contract from
  // committing to bets it cannot pay out.
  uint128 public lockedInBets;

  // Structure representing a bet.
  struct Bet {
    // Wager amount in wei.
    uint80 amount;
    // Modulo of a game.
    uint8 modulo;
    // Number of winning outcomes, used to compute winning payment (* modulo/rollUnder),
    // and used instead of mask for games with modulo > MAX_MASK_MODULO.
    uint8 rollUnder;
    // Address of a gambler, used to pay out winning bets.
    address payable gambler;
    // Block number of placeBet tx.
    uint40 placeBlockNumber;
    // Bit mask representing winning bet outcomes
    uint216 mask;
  }

  // Mapping from commits to all currently active & processed bets.
  mapping(uint => Bet) bets;

  // Payment events
  event FailedPayment(address indexed beneficiary, uint amount, uint commit);
  event Payment(address indexed beneficiary, uint amount, uint commit);
  event JackpotPayment(address indexed beneficiary, uint amount, uint commit);

  // event is emitted in placeBet to record commit in the logs.
  event Commit(uint commit, uint source);

  // Constructor.
  constructor (address payable _owner1, address payable _owner2,
               address _secretSigner, address _croupier, uint128 _maxProfit
               ) public payable {
    owner1 = _owner1;
    owner2 = _owner2;
    secretSigner = _secretSigner;
    croupier = _croupier;
    require(_maxProfit < MAX_AMOUNT, "maxProfit should be a sane number.");
    maxProfit = _maxProfit;
    killed = false;
  }

  // Modifier on methods invokable only by contract owners.
  modifier onlyOwner {
     require(msg.sender == owner1 || msg.sender == owner2, "OnlyOwner methods called by non-owner.");
    _;
  }

  // Modifier on methods invokable only by croupier.
  modifier onlyCroupier {
    require(msg.sender == croupier, "OnlyCroupier methods called by non-croupier.");
    _;
  }

  // Fallback function deliberately left empty. It's primary use case
  // is to top up the bank roll.
  function() external payable {
    require(msg.data.length == 0);
  }

  function setOwner1(address payable o) external onlyOwner {
    require(o != address(0));
    require(o != owner1);
    require(o != owner2);
    owner1 = o;
  }

  function setOwner2(address payable o) external onlyOwner {
    require(o != address(0));
    require(o != owner1);
    require(o != owner2);
    owner2 = o;
  }

  // Change the secretSigner address, only owner can call this function
  function setSecretSigner(address newSecretSigner) external onlyOwner {
    secretSigner = newSecretSigner;
  }

  // Change the croupier address, only owner can call this function
  function setCroupier(address newCroupier) external onlyOwner {
    croupier = newCroupier;
  }

  // Change max bet reward. Setting this to zero effectively disables betting.
  function setMaxProfit(uint128 _maxProfit) public onlyOwner {
    require(_maxProfit < MAX_AMOUNT, "maxProfit should be a sane number.");
    maxProfit = _maxProfit;
  }

  // This function is used to increase the jackpot fund. Cannot be used to decrease it.
  function increaseJackpot(uint increaseAmount) external onlyOwner {
    require(increaseAmount <= address(this).balance, "Increase amount larger than balance.");
    require(jackpotSize + lockedInBets + increaseAmount <= address(this).balance, "Not enough funds.");
    jackpotSize += uint128(increaseAmount);
  }

  // Funds withdrawal to cover costs of croupier operation.
  function withdrawFunds(address payable beneficiary, uint withdrawAmount) public onlyOwner {
    require(withdrawAmount <= address(this).balance, "Withdraw amount larger than balance.");
    require(jackpotSize + lockedInBets + withdrawAmount <= address(this).balance, "Not enough funds.");
    sendFunds(beneficiary, withdrawAmount, withdrawAmount, 0);
  }

  // Contract may be destroyed only when there are no ongoing bets,
  // either settled or refunded. All funds are transferred to contract owner.
  function kill() external onlyOwner {
    require(lockedInBets == 0, "All bets should be processed (settled or refunded) before self-destruct.");
    killed = true;
    jackpotSize = 0;
    owner1.transfer(address(this).balance);
  }

  function getBetInfoByReveal(uint reveal) external view returns (uint commit, uint amount, uint8 modulo, uint8 rollUnder, uint placeBlockNumber, uint mask, address gambler) {
    commit = uint(keccak256(abi.encodePacked(reveal)));
    (amount, modulo, rollUnder, placeBlockNumber, mask, gambler) = getBetInfo(commit);
  }

  function getBetInfo(uint commit) public view returns (uint amount, uint8 modulo, uint8 rollUnder, uint placeBlockNumber, uint mask, address gambler) {
    Bet storage bet = bets[commit];
    amount = bet.amount;
    modulo = bet.modulo;
    rollUnder = bet.rollUnder;
    placeBlockNumber = bet.placeBlockNumber;
    mask = bet.mask;
    gambler = bet.gambler;
  }

  /// Betting logic
  // Bet states:
  //  amount == 0 && gambler == 0 - 'clean' (can place a bet)
  //  amount != 0 && gambler != 0 - 'active' (can be settled or refunded)
  //  amount == 0 && gambler != 0 - 'processed' (can clean storage)
  //
  //  NOTE: Storage cleaning is not implemented in this contract version; it will be added
  //        with the next upgrade to prevent polluting Ethereum state with expired bets.

  // Bet placing transaction - issued by the player.
  //  betMask         - bet outcomes bit mask for modulo <= MAX_MASK_MODULO,
  //                    [0, betMask) for larger modulos.
  //  modulo          - game modulo.
  //  commitLastBlock - number of the maximum block where "commit" is still considered valid.
  //  commit          - Keccak256 hash of some secret "reveal" random number, to be supplied
  //                    by the croupier bot in the settleBet transaction. Supplying
  //                    "commit" ensures that "reveal" cannot be changed behind the scenes
  //                    after placeBet have been mined.
  //  v, r, s            - components of ECDSA signature of (commitLastBlock, commit). v is
  //                    guaranteed to alwtays equal 27.
  //  source          - game identifier

  // Commit, being essentially random 256-bit number, is used as a unique bet identifier in
  // the 'bets' mapping.

  // Commits are signed with a block limit to ensure that they are used at most once - otherwise
  // it would be possible for a masternode to place a bet with a known commit/reveal pair and tamper
  // with the blockhash. Croupier guarantees that commitLastBlock will always be not greater than
  // placeBet block number plus BET_EXPIRATION_BLOCKS.
  function placeBet(uint betMask, uint modulo, uint commitLastBlock, uint commit, uint8 v, bytes32 r, bytes32 s, uint source) external payable {
    require(!killed, "contract killed");
    // Check that the bet is in 'clean' state.
    Bet storage bet = bets[commit];
    require(bet.gambler == address(0), "Bet should be in a 'clean' state.");

    // Validate input data ranges.
    require(modulo >= 4 && modulo <= MAX_MODULO, "Modulo should be within range.");
    require(msg.value >= MIN_BET && msg.value <= MAX_AMOUNT, "Amount should be within range.");
    require(betMask > 0 && betMask < MAX_BET_MASK, "Mask should be within range.");

    // Check that commit is valid - it has not expired and its signature is valid.
    require(block.number <= commitLastBlock, "Commit has expired.");
    bytes32 hash = keccak256(abi.encodePacked(commitLastBlock, commit));
    bytes32 signatureHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    require(secretSigner == ecrecover(signatureHash, v, r, s), "ECDSA signature is not valid.");

    uint rollUnder;
    uint mask;

    if (modulo <= MASK_MODULO_40) {
      // Small modulo games specify bet outcomes via bit mask.
      // rollUnder is a number of 1 bits in this mask (population count).
      // This magic looking formula is an efficient way to compute population
      // count on EVM for numbers below 2**40.
      rollUnder = ((betMask * POPCNT_MULT) & POPCNT_MASK) % POPCNT_MODULO;
      mask = betMask;
    } else if (modulo <= MASK_MODULO_40 * 2) {
      rollUnder = getRollUnder(betMask, 2);
      mask = betMask;
    } else if (modulo == 100) {
      require(betMask > 0 && betMask <= modulo, "High modulo range, betMask larger than modulo.");
      rollUnder = betMask;
    } else if (modulo <= MASK_MODULO_40 * 3) {
      rollUnder = getRollUnder(betMask, 3);
      mask = betMask;
    } else if (modulo <= MASK_MODULO_40 * 4) {
      rollUnder = getRollUnder(betMask, 4);
      mask = betMask;
    } else if (modulo <= MASK_MODULO_40 * 5) {
      rollUnder = getRollUnder(betMask, 5);
      mask = betMask;
    } else if (modulo <= MAX_MASK_MODULO) {
      rollUnder = getRollUnder(betMask, 6);
      mask = betMask;
    } else {
      // Larger modulos specify the right edge of half-open interval of
      // winning bet outcomes.
      require(betMask > 0 && betMask <= modulo, "High modulo range, betMask larger than modulo.");
      rollUnder = betMask;
    }

    // Winning amount and jackpot increase.
    uint possibleWinAmount;
    uint jackpotFee;

    (possibleWinAmount, jackpotFee) = getWinAmount(msg.value, modulo, rollUnder);

    // Enforce max profit limit.
    require(possibleWinAmount <= msg.value + maxProfit, "maxProfit limit violation.");

    // Lock funds.
    lockedInBets += uint128(possibleWinAmount);
    jackpotSize += uint128(jackpotFee);

    // Check whether contract has enough funds to process this bet.
    require(jackpotSize + lockedInBets <= address(this).balance, "Cannot afford to lose this bet.");

    // Record commit in logs.
    emit Commit(commit, source);

    // Store bet parameters on blockchain.
    bet.amount = uint80(msg.value);
    bet.modulo = uint8(modulo);
    bet.rollUnder = uint8(rollUnder);
    bet.placeBlockNumber = uint40(block.number);
    bet.mask = uint216(mask);
    bet.gambler = msg.sender;
  }

  function getRollUnder(uint betMask, uint n) private pure returns (uint rollUnder) {
    rollUnder += (((betMask & MASK40) * POPCNT_MULT) & POPCNT_MASK) % POPCNT_MODULO;
    for (uint i = 1; i < n; i++) {
      betMask = betMask >> MASK_MODULO_40;
      rollUnder += (((betMask & MASK40) * POPCNT_MULT) & POPCNT_MASK) % POPCNT_MODULO;
    }
    return rollUnder;
  }

  // This is the method used to settle 99% of bets. To process a bet with a specific
  // "commit", settleBet should supply a "reveal" number that would Keccak256-hash to
  // "commit". "blockHash" is the block hash of placeBet block as seen by croupier; it
  // is additionally asserted to prevent changing the bet outcomes on Ethereum reorgs.
  function settleBet(uint reveal, bytes32 blockHash) external onlyCroupier {
    uint commit = uint(keccak256(abi.encodePacked(reveal)));

    Bet storage bet = bets[commit];
    uint placeBlockNumber = bet.placeBlockNumber;

    // Check that bet has not expired yet (see comment to BET_EXPIRATION_BLOCKS).
    require(block.number > placeBlockNumber, "settleBet in the same block as placeBet, or before.");
    require(block.number <= placeBlockNumber + BET_EXPIRATION_BLOCKS, "Blockhash can't be queried by EVM.");
    require(blockhash(placeBlockNumber) == blockHash, "blockHash invalid");

    // Settle bet using reveal and blockHash as entropy sources.
    settleBetCommon(bet, reveal, blockHash, commit);
  }

  // Common settlement code for settleBet.
  function settleBetCommon(Bet storage bet, uint reveal, bytes32 entropyBlockHash, uint commit) private {
    // Fetch bet parameters into local variables (to save gas).
    uint amount = bet.amount;
    uint modulo = bet.modulo;
    uint rollUnder = bet.rollUnder;
    address payable gambler = bet.gambler;

    // Check that bet is in 'active' state.
    require(amount != 0, "Bet should be in an 'active' state");

    // Move bet into 'processed' state already.
    bet.amount = 0;

    // The RNG - combine "reveal" and blockhash of placeBet using Keccak256. masternodes
    // not aware of "reveal" and cannot deduce it from "commit" (as Keccak256
    // preimage is intractable), and house is unable to alter the "reveal" after
    // placeBet have been mined (as Keccak256 collision finding is also intractable).
    bytes32 entropy = keccak256(abi.encodePacked(reveal, entropyBlockHash));

    // Do a roll by taking a modulo of entropy. Compute winning amount.
    uint roll = uint(entropy) % modulo;

    uint winAmount;
    uint _jackpotFee;
    (winAmount, _jackpotFee) = getWinAmount(amount, modulo, rollUnder);

    uint rollWin = 0;
    uint jackpotWin = 0;

    // Determine roll outcome.
    if ((modulo != 100) && (modulo <= MAX_MASK_MODULO)) {
      // For small modulo games, check the outcome against a bit mask.
      if ((2 ** roll) & bet.mask != 0) {
        rollWin = winAmount;
      }
    } else {
      // For larger modulos, check inclusion into half-open interval.
      if (roll < rollUnder) {
        rollWin = winAmount;
      }
    }

    // Unlock the bet amount, regardless of the outcome.
    lockedInBets -= uint128(winAmount);

    // Roll for a jackpot (if eligible).
    if (amount >= MIN_JACKPOT_BET) {
      // The second modulo, statistically independent from the "main" roll.
      // Effectively you are playing two games at once!
      uint jackpotRng = (uint(entropy) / modulo) % JACKPOT_MODULO;

      // Bingo!
      if (jackpotRng == 0) {
        jackpotWin = jackpotSize;
        jackpotSize = 0;
      }
    }

    // Log jackpot win.
    if (jackpotWin > 0) {
      emit JackpotPayment(gambler, jackpotWin, commit);
    }

    // Send the funds to gambler.
    sendFunds(gambler, rollWin + jackpotWin == 0 ? 1 wei : rollWin + jackpotWin, rollWin, commit);
  }

  // Refund transaction - return the bet amount of a roll that was not processed in a
  // due timeframe. Processing such blocks is not possible due to EVM limitations (see
  // BET_EXPIRATION_BLOCKS comment above for details). In case you ever find yourself
  // in a situation like this, just contact us, however nothing
  // precludes you from invoking this method yourself.
  function refundBet(uint commit) external {
    // Check that bet is in 'active' state.
    Bet storage bet = bets[commit];
    uint amount = bet.amount;

    require(amount != 0, "Bet should be in an 'active' state");

    // Check that bet has already expired.
    require(block.number > bet.placeBlockNumber + BET_EXPIRATION_BLOCKS, "Bet is not expired yet.");

    // Move bet into 'processed' state, release funds.
    bet.amount = 0;

    uint winAmount;
    uint jackpotFee;
    (winAmount, jackpotFee) = getWinAmount(amount, bet.modulo, bet.rollUnder);

    lockedInBets -= uint128(winAmount);
    if (jackpotSize >= jackpotFee) {
      jackpotSize -= uint128(jackpotFee);
    }

    // Send the refund.
    sendFunds(bet.gambler, amount, amount, commit);
  }

  // Get the expected win amount after jackpot fee is subtracted.
  function getWinAmount(uint amount, uint modulo, uint rollUnder) private pure returns (uint winAmount, uint jackpotFee) {
    require(0 < rollUnder && rollUnder <= modulo, "Win probability out of range.");

    jackpotFee = amount >= MIN_JACKPOT_BET ? JACKPOT_FEE : 0;

    require(jackpotFee <= amount, "Bet doesn't even cover jackpot fee.");

    winAmount = (amount - jackpotFee) * modulo / rollUnder;
  }

  // Helper routine to process the payment.
  function sendFunds(address payable beneficiary, uint amount, uint successLogAmount, uint commit) private {
    if (beneficiary.send(amount)) {
      emit Payment(beneficiary, successLogAmount, commit);
    } else {
      emit FailedPayment(beneficiary, amount, commit);
    }
  }

  // This are some constants making O(1) population count in placeBet possible.
  uint constant POPCNT_MULT = 0x0000000000002000000000100000000008000000000400000000020000000001;
  uint constant POPCNT_MASK = 0x0001041041041041041041041041041041041041041041041041041041041041;
  uint constant POPCNT_MODULO = 0x3F;
  uint constant MASK40 = 0xFFFFFFFFFF;
  uint constant MASK_MODULO_40 = 40;
}
