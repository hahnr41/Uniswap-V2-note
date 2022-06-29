pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo; //收取手续费地址
    address public feeToSetter; //管理收取手续费用地址

    mapping(address => mapping(address => address)) public getPair; //获取交易对地址的映射
    address[] public allPairs; // 记录所有交易对的数组

    /**
     *创建交易对事件
     *@param token0 第一个代币合约地址
     *@param token1 第二个代币合约地址
     *@param pair 交易对合约地址
     *@param length 当下交易对的数量
     */
    event PairCreated(address indexed token0, address indexed token1, address pair, uint); 

    /**
     *构造函数
     *设置管理收取手续费的地址
     */
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    /**
     *返回现存交易对的数量
     */
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    /**
     *交易对创建合约
     *@param tokenA 第一个代币合约地址
     *@param tokenB 第二个代币合约地址
     *@param pair 返回值为两个代币组成的交易对合约地址
     */
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES'); 
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA); 
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS'); 
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // 要求必须为未创建过的交易对
        bytes memory bytecode = type(UniswapV2Pair).creationCode;  //获取UniswawpV2Pair的创建字节码
        bytes32 salt = keccak256(abi.encodePacked(token0, token1)); //以两个代币合约地址编码哈希值创建salt值
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt) 
        }
        IUniswapV2Pair(pair).initialize(token0, token1); 
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // 保证不同顺序的tokenA，tokenB映射到一个pair中
        allPairs.push(pair); //数组中记录新的交易对
        emit PairCreated(token0, token1, pair, allPairs.length); 
    }

    /**
     * 校验msg.sender是否为管理收取手续费的地址
     * 设置收取手续费地址
     */
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    /**
     *校验msg.sender是否为管理收取手续费的地址
     *更换管理收取手续费的地址
     */
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
