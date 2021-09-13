// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.9.0;

contract Abatement {

    uint totalUsers; // Bidding mechanism starts when `totalUsers' are registration
    uint deadline; // All transfers can be refunded if `deadline' is reached
    int fixDeposit; // Fixed deposit

    struct User {
        address add; // User's address
        int deposit; // Amount initially deposited
        int toRefund; // Total amount to refund, includes also bids
        bytes32 encryptedBid; // Encrypted bid
        int[] plainBid; // Plaintext bid
        bool completedAction; // User has completed action in the current phase
    }

    User[] private users; // Array of users

    mapping (address => bool) private isActive; // True if the user's address is active
    mapping (address => uint) private getID; // ID's 0, 1, 2, ... connected to addresses

    uint private numberActiveUsers; // Total number of active users
    uint private state; // 0: register 1: deposit 2: commit 3: reveal 4: propose 5: evaluate

    uint private proposerID; // ID of proposer
    int[] private proposal; // Proposal to evaluate

    modifier inState (uint _state) { // Requires that we're in the correct phase
        require(state == _state, "Action not available at this point");
        _;
    }

    modifier activeUsers { // Requires that address belongs to active user
        require(isActive[msg.sender], "Action only available to active users");
        _;
    }

    modifier onlyProposer { // Requires that address belongs to the proposer
        require(getID[msg.sender] == proposerID, "Action only available to proposer");
        _;
    }
    
    constructor (uint _totalUsers, uint _deadline, int _fixDeposit) {
        totalUsers = _totalUsers;
        deadline = _deadline;
        fixDeposit = _fixDeposit;
        state = 0;
    }

    function sum (int[] memory _arr) pure internal returns (int) { // Computes sum of array
        int total = 0;
        for (uint j = 0; j < _arr.length; j++) {
            total += _arr[j];
        }
        return total;
    }

    function completedPhase () internal returns (bool) { // Checks if phase is completed
        for (uint j = 0; j < numberActiveUsers; j++) {
            if (!users[j].completedAction)
                return false; // Not completed
        }
        for (uint j = 0; j < numberActiveUsers; j++) { // Completed
            users[j].completedAction = false;
        }
        state ++;
        return true;
    }

    function register () public inState(0) { // Registration
        require(!isActive[msg.sender], "User already registered");
        User memory user;
        user.add = msg.sender;
        users.push(user);
        isActive[msg.sender] = true;
        getID[msg.sender] = numberActiveUsers ++;
        if (numberActiveUsers == totalUsers)
            state ++;
    }

    function deposit () public payable activeUsers inState(1) { // Deposit
        uint i = getID[msg.sender];
        users[i].deposit = int(msg.value);
        users[i].toRefund = int(msg.value);
        users[i].completedAction = true;
        completedPhase();
    }

    function commit (bytes32 _encryptedbid) public activeUsers inState(2) { // Commit to bid
        uint i = getID[msg.sender];
        users[i].encryptedBid = _encryptedbid;
        users[i].completedAction = true;
        completedPhase();
    }

    function reveal (int[] memory _bid) public payable activeUsers inState(3) { // Reveal bid, must match encrypted commitment
        uint i = getID[msg.sender];
        require(users[i].encryptedBid == keccak256(abi.encodePacked(_bid)), "Bid does not match encrypted commitment");
        require(sum(_bid) <= int(msg.value), "Transacted amount does not cover bid");
        users[i].toRefund += int(msg.value);
        users[i].plainBid = _bid;
        users[i].completedAction = true;
        if (completedPhase())
            selectProposer(); // All bids available, can compute net bids
    }

    function selectProposer () internal {
        int maxBid = 0;
        uint maxID = 0;
        for (uint i = 0; i < numberActiveUsers; i++) {
            int netBid = 0;
            for (uint j = 0; j < numberActiveUsers; j++) {
                netBid += users[i].plainBid[j] - users[j].plainBid[i];
            }
            if (netBid > maxBid) {
                maxBid = netBid;
                maxID = i;
            }
        }
        proposerID = maxID;
        for (uint j = 0; j < numberActiveUsers; j++) { // Execute proposer's bids
            users[j].toRefund += users[proposerID].plainBid[j];
            users[proposerID].toRefund -= users[proposerID].plainBid[j];
        }
    }

    function propose (int[] memory _proposal) public payable onlyProposer inState(4) { // Proposal
        require(sum(_proposal) <= int(msg.value), "Transacted amount does not cover proposal");
        users[proposerID].toRefund += int(msg.value);
        proposal = _proposal;
        state ++;
    }

    function evaluate (bool _eval) public activeUsers inState(5) { // Evaluate proposal
        uint i = getID[msg.sender];
        users[i].completedAction = true;
        if (_eval == false) { // Rejection
            executeTransfers();
            isActive[users[proposerID].add] = false; // Proposer is kicked out
            for (uint j = proposerID; j < numberActiveUsers - 1; j++) {
                users[j] = users[j+1]; // Shift later users one step to "overwrite" proposer
                getID[users[j].add] --;
            }
            users.pop();
            numberActiveUsers --;
            for (uint j = 0; j < numberActiveUsers; j++) {
                users[j].completedAction = false;
            }
            state = 1;
        }
        else {
            if (completedPhase()) { // Accepted
                for (uint j = 0; j < numberActiveUsers; j++) {
                    users[j].toRefund += proposal[j] - users[j].deposit + fixDeposit;
                    users[proposerID].toRefund -= proposal[j] - users[j].deposit + fixDeposit;
                }
                executeTransfers();
            }
        }
    }

    function executeTransfers () internal { // Transfer funds back to users
        for (uint j = 0; j < numberActiveUsers; j++) {
            int amount = users[j].toRefund;
            users[j].toRefund = 0;
            payable(users[j].add).transfer(uint(amount));
        }
    }

    function abort () public { // Refunds can be made if deadline has passed
        require(block.timestamp >= deadline, "Deadline has not yet been reached");
        executeTransfers();
    }

    function DEBUGgetHash (int[] memory _arr) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_arr));
    }
}
