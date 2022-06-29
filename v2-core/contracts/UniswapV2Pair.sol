pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint; //使用SafeMath库
    using UQ112x112 for uint224; //用于处理二进制定点数的库

    uint public constant MINIMUM_LIQUIDITY = 10**3; //定义常量最小流动性1000
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)'))); //定义transfer的函数选择器常量
    /**
     *工厂合约与两个代币的合约地址
     */
    address public factory; 
    address public token0;
    address public token1;
    /**
     *两个代币在交易对中的数量
     *blockTimestampLast记录是否是区块的第一笔交易
     *uint122+uint122+uint32 长度为256
     */
    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves
    /**
     *代币的价格最后累计，用于Uniswap提供的预言机上，在每个区块的第一笔交易中更新
     *k值为代币数量之积
     */
    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    /**
     *重入锁
     */
    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }
    
    /**
     *获取对应的代币数量与时间戳
     */
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /**
     *使用call调用transfer方法给to地址发送token代币，能够在未知token的transfer方法实现的前提下调用
     *require保证了返回值为true或者data的长度为0或者解码后为true
     */
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    // 铸币事件
    event Mint(address indexed sender, uint amount0, uint amount1);
    // 燃烧事件
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    // swap事件
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    // 同步事件
    event Sync(uint112 reserve0, uint112 reserve1);

    // 构造函数 将factory设置为msg.sender
    constructor() public {
        factory = msg.sender;
    }

    /**
     *初始化方法，要求调用者为factory
     */
    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }
 
    /**
     *更新对应token的余额
     *在每个区块的第一次调用时，更新价格最后计算值
     *用于价格预言机
     */
    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW'); // 要求两个余额小于uint112极大值
        uint32 blockTimestamp = uint32(block.timestamp % 2**32); // 将区块时间戳转化为uint32格式
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired 计算时间差
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) { // 判断是否timeElapsed > 0
            // * never overflows, and + overflow is desired
            // 价格0最后计算值 = _reserve1 / _reserve0 * timeElapsed 价格计算进行了与时间反比的数值累加，计算出相对平衡的市场价格
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed; 
            // 价格1最后计算值 = _reserve0 * 2*112 / _reserve1 * timeElapsed
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed; 
        }
        reserve0 = uint112(balance0); 
        reserve1 = uint112(balance1); 
        blockTimestampLast = blockTimestamp; 
        emit Sync(reserve0, reserve1); 
    }

    // 计算给开发团队分成手续费的部分
    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo(); 
        feeOn = feeTo != address(0); 
        uint _kLast = kLast; // gas savings  获取k值
        if (feeOn) { // 如果开发团队收取手续费
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1)); 
                uint rootKLast = Math.sqrt(_kLast); 
                if (rootK > rootKLast) { // 如果reserve0 * reserve1 的平方根大于k值平方根
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast)); // 分子 = totalSupply * (rootk - rookLast)
                    uint denominator = rootK.mul(5).add(rootKLast); // 分母 = rook * 5 + rookLast
                    uint liquidity = numerator / denominator; // 流动性 = 分子 / 分母
                    if (liquidity > 0) _mint(feeTo, liquidity); // 如果流动性大于0 ，将流动性铸给feeTo地址
                }
            }
        } else if (_kLast != 0) {
            kLast = 0; 
        }
    }
    
    // 铸造流动性
    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); 
        uint balance0 = IERC20(token0).balanceOf(address(this)); 
        uint balance1 = IERC20(token1).balanceOf(address(this)); 
        uint amount0 = balance0.sub(_reserve0); // 计算代币余额与记录值之差
        uint amount1 = balance1.sub(_reserve1); 

        bool feeOn = _mintFee(_reserve0, _reserve1); // 是否给开发团队手续费分成
        // 获取totalSupply 必须在此定义，totalSupply会在_mintFee中更新
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            // 流动性 = amount0 * amount1 的开方 - MINMUM_LIQUIDITY
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY); 
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens 锁定最小流动性
        } else {
            // liquidity = min( amount0 * _totalSupply / _reserve0, amount1 * _totalSupply / _reserve1)
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity); // 铸造流动性

        _update(balance0, balance1, _reserve0, _reserve1); // 更新代币库存
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date 
        emit Mint(msg.sender, amount0, amount1);
    }

    // 销毁lp代币返回token
    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings 获取代币库存
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this)); // 获取当前合约内token余额
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)]; // 获取合约中流动性数量

        bool feeOn = _mintFee(_reserve0, _reserve1); // 开发团队手续费
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution 使用余额按比例分配token数量
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity); // 销毁lp代币
        _safeTransfer(_token0, to, amount0); //发送对应数量的token
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this)); // 更新balance
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1); // 更新代币库存
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to); // 触发事件
    }

    // 代币之间swap
    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT'); //要求amount0，amount1大于0
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings 获取代币库存
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY'); // 要求输出数量小于库存量

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors 标记_token{0,1}作用域，避免堆栈过深
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO'); // 要求接收地址不为代币合约地址
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens 发送对应的token
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data); // 闪点贷
        balance0 = IERC20(_token0).balanceOf(address(this)); // 计算新的balance
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0; // 计算pair中增加的token数量
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT'); // 要求代币数量必须变化
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3)); //考虑30bp的手续费
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K'); //要求k值不变小
        }

        _update(balance0, balance1, _reserve0, _reserve1); //更新代币库存
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves 多余的币转出
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
