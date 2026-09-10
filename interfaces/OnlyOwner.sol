// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;


// 定义一个isOwner字典，只有被允许的owner才能使用onlyOwner的相关函数
contract OnlyOwner {
    mapping(address => bool) public isOwner;

    constructor()  payable {
        isOwner[msg.sender] = true;
    }

    modifier onlyOwner() {  // 相当于python内的修饰器
        require(isOwner[msg.sender], "Not owner!");  //要求发送者是合约创建者，如果不是，则返回错误信息
        _;
    }

    function addOwner(address _newOwner) public onlyOwner {
        isOwner[_newOwner] = true;
    }
    
    function addOwners(address[] memory _newOwners) public onlyOwner {
    for (uint256 i = 0; i < _newOwners.length; i++) {
        isOwner[_newOwners[i]] = true;
    }
  }
}
