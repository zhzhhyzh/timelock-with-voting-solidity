// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract TimeLock {

    // Events for tracking
    event TransactionQueued(bytes32 txId, address indexed target, uint value, string signature, bytes data, uint executeAt);
    event TransactionExecuted(bytes32 txId);
    event TransactionCancelled(bytes32 txId);
    event NewOwnerProposed(address indexed proposedOwner);
    event OwnerChanged(address indexed newOwner);
    event VotingFinalized(address indexed newOwner);

    // Struct for storing details of a scheduled transaction
    struct Transaction {
        address target;
        uint value;
        string signature;
        bytes data;
        uint executeAt;
        bool executed;
    }

    address public owner;
    uint public minGracePeriod;
    uint public maxGracePeriod;

    // Transactions map to track queued transactions
    mapping(bytes32 => Transaction) public queuedTransactions;

    // Vote owner variable
    mapping(address => uint) public votes;
    address[] public registeredUsers;  // List of all registered users
    mapping(address => bool) public isRegistered;  // Check if user is registered
    address public proposedOwner;
    uint public voteThreshold;  // Auto calculate based on registered users
    uint public votingStartTime;
    uint public votingEndTime;
    uint public proposalDeadline;
    bool public votingActive;

    constructor(uint _minGracePeriod, uint _maxGracePeriod) {
        owner = msg.sender;
        minGracePeriod = _minGracePeriod;
        maxGracePeriod = _maxGracePeriod;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can execute this.");
        _;
    }

    modifier validGracePeriod(uint _gracePeriod) {
        require(_gracePeriod >= minGracePeriod && _gracePeriod <= maxGracePeriod, "Invalid grace period.");
        _;
    }

    modifier duringProposalPhase() {
        require(block.timestamp <= proposalDeadline, "Proposal phase has ended.");
        _;
    }

    modifier duringVotingPhase() {
        require(block.timestamp >= proposalDeadline && block.timestamp <= votingEndTime, "Voting phase is not active.");
        _;
    }

    modifier afterVotingPhase() {
        require(block.timestamp > votingEndTime, "Voting period has not ended.");
        _;
    }

    // QUEUE a transaction
    function queueTransaction(
        address _target, 
        uint _value, 
        string memory _signature, 
        bytes memory _data, 
        uint _gracePeriod
    ) public onlyOwner validGracePeriod(_gracePeriod) returns (bytes32) {
        bytes32 txId = keccak256(abi.encode(_target, _value, _signature, _data, block.timestamp + _gracePeriod));
        queuedTransactions[txId] = Transaction({
            target: _target,
            value: _value,
            signature: _signature,
            data: _data,
            executeAt: block.timestamp + _gracePeriod,
            executed: false
        });
        emit TransactionQueued(txId, _target, _value, _signature, _data, block.timestamp + _gracePeriod);
        return txId;
    }

    // CANCEL a transaction
    function cancelTransaction(bytes32 _txId) public onlyOwner {
        require(queuedTransactions[_txId].target != address(0), "Transaction does not exist.");
        require(!queuedTransactions[_txId].executed, "Transaction already executed.");

        delete queuedTransactions[_txId];
        emit TransactionCancelled(_txId);
    }

    // EXECUTE a transaction
    function executeTransaction(bytes32 _txId) public payable onlyOwner {
        Transaction storage txn = queuedTransactions[_txId];
        require(txn.target != address(0), "Transaction does not exist.");
        require(!txn.executed, "Transaction already executed.");
        require(block.timestamp >= txn.executeAt, "Transaction is still locked.");

        // Perform the transaction call
        (bool success, ) = txn.target.call{value: txn.value}(txn.data);
        require(success, "Transaction failed.");

        txn.executed = true;
        emit TransactionExecuted(_txId);
    }

    // Start the voting process with a time lock
    function startVoting() public onlyOwner {
        require(!votingActive, "Voting is already active.");
        require(registeredUsers.length > 0, "No registered users available.");

        // Set the deadlines for proposal and voting
        votingStartTime = block.timestamp;
        proposalDeadline = block.timestamp + 2 minutes; // First 2 minutes for proposing
        votingEndTime = block.timestamp + 10 minutes; // Total of 10 minutes

        votingActive = true;

        // Recalculate vote threshold based on 51% of registered users
        updateVoteThreshold();
    }

    // PROPOSE a new owner during the first 2 minutes
    function proposeOwner(address _proposedOwner) public duringProposalPhase {
        require(proposedOwner == address(0), "Owner is already proposed.");
        proposedOwner = _proposedOwner;
        emit NewOwnerProposed(_proposedOwner);
    }

    // VOTE for proposed owner (voting happens between 2 and 10 minutes)
    function voteForOwner() public duringVotingPhase {
        require(proposedOwner != address(0), "No owner proposed.");
        require(isRegistered[msg.sender], "Only registered users can vote.");
        require(votes[msg.sender] == 0, "Already voted.");

        votes[msg.sender] += 1;

        // Check if vote threshold has been met
        if (getTotalVotes() >= voteThreshold) {
            finalizeOwner();
        }
    }

    // FINALIZE the voting process after 10 minutes
    function finalizeOwner() public afterVotingPhase {
        require(proposedOwner != address(0), "No proposed owner.");
        
        // Change the owner
        owner = proposedOwner;
        emit OwnerChanged(proposedOwner);
        emit VotingFinalized(proposedOwner);

        // Reset the voting state
        resetVoting();
    }

    // Register a user
    function registerUser(address _user) public onlyOwner {
        require(!isRegistered[_user], "User already registered.");
        registeredUsers.push(_user);
        isRegistered[_user] = true;

        // Recalculate the vote threshold after registration
        updateVoteThreshold();
    }

    // Deregister a user
    function deregisterUser(address _user) public onlyOwner {
        require(isRegistered[_user], "User not registered.");

        // Remove the user from the registeredUsers array
        for (uint i = 0; i < registeredUsers.length; i++) {
            if (registeredUsers[i] == _user) {
                registeredUsers[i] = registeredUsers[registeredUsers.length - 1];  // Replace with the last user
                registeredUsers.pop();  // Remove the last user
                break;
            }
        }

        isRegistered[_user] = false;

        // Recalculate the vote threshold after deregistration
        updateVoteThreshold();
    }

    // Check if address is registered
    function isUserRegistered(address _user) public view returns (bool) {
        return isRegistered[_user];
    }

    // Reset voting process after it ends
    function resetVoting() internal {
        proposedOwner = address(0);
        votingActive = false;

        for (uint i = 0; i < registeredUsers.length; i++) {
            votes[registeredUsers[i]] = 0;
        }
    }

    // Adjust grace period range
    function updateGracePeriod(uint _minGracePeriod, uint _maxGracePeriod) public onlyOwner {
        require(_minGracePeriod <= _maxGracePeriod, "Invalid grace period range.");
        minGracePeriod = _minGracePeriod;
        maxGracePeriod = _maxGracePeriod;
    }

    // Automatically calculate vote threshold (51% of registered users, rounded up)
    function updateVoteThreshold() internal {
        uint totalRegisteredUsers = registeredUsers.length;
        voteThreshold = (totalRegisteredUsers * 51 + 99) / 100;  // Equivalent to rounding up (51% rule)
    }

    // Get total votes cast
    function getTotalVotes() internal view returns (uint totalVotes) {
        totalVotes = 0;
        for (uint i = 0; i < registeredUsers.length; i++) {
            totalVotes += votes[registeredUsers[i]];
        }
    }
}
