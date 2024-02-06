// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { BaseScript } from "./Base.s.sol";

contract EXAIP3Script is BaseScript {
  using Strings for address;

  uint40 public constant START_DATE = 1_717_200_000; // 2024-06-01T00:00:00.000Z
  uint40 public constant DURATION = 4 * 365 days; // 4 years
  address public constant SENDER = 0xC0d6Bc5d052d1e74523AD79dD5A954276c9286D3; // admin multisig

  function run() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 112_275_980);
    address exa = deployment("EXA");
    address sablier = deployment("SablierV2LockupLinear");
    TimelockController timelock = TimelockController(payable(deployment("TimelockController")));

    Receiver[] memory receivers = new Receiver[](117);
    receivers[0] = Receiver({ account: 0xF35e261393F9705e10B378C6785582B2a5A71094, amount: 233_030.17295818e18 });
    receivers[1] = Receiver({ account: 0xF6Da9e9D73d7893223578D32a95d6d7de5522767, amount: 221_923.781730444e18 });
    receivers[2] = Receiver({ account: 0x3cf3c6a96357e26DE5c6F8Be745DC453AAD59249, amount: 71_458.137814729e18 });
    receivers[3] = Receiver({ account: 0x87bF260aef0Efd0AB046417ba290f69aE24C1642, amount: 68_072.488520535e18 });
    receivers[4] = Receiver({ account: 0x2f0D2701b620B639e44E1824446a0d63D7a05C31, amount: 62_027.864118358e18 });
    receivers[5] = Receiver({ account: 0x551Cfb91aCd97572BA1C2B177EEB667c207CE759, amount: 56_526.380676054e18 });
    receivers[6] = Receiver({ account: 0x8789E0a45b270d7fd9aeD1a72682f6530a722c50, amount: 42_921.271046653e18 });
    receivers[7] = Receiver({ account: 0xd1aDb83CD6390c6bBd619Fdd79fC37F9f58f1a4C, amount: 39_478.160400306e18 });
    receivers[8] = Receiver({ account: 0x166ed9f7A56053c7c4E77CB0C91a9E46bbC5e8b0, amount: 25_772.897997241e18 });
    receivers[9] = Receiver({ account: 0x516E5B72C3fD2D2E59835C82005ba6A2BC5788A4, amount: 22_173.407967006e18 });
    receivers[10] = Receiver({ account: 0xAF935695EB156b6fe95af0E83Daafbd62CA37Af5, amount: 21_535.804478836e18 });
    receivers[11] = Receiver({ account: 0x316BE293C8f2380769e7b7e7382679FE5a3b6600, amount: 20_735.329919272e18 });
    receivers[12] = Receiver({ account: 0x54240C950fF793A4eB5895a56F859216cB1c3f0D, amount: 17_111.353966691e18 });
    receivers[13] = Receiver({ account: 0x654f1C992758b0Dd491e3ac67F084caCF98AA77C, amount: 11_476.260044126e18 });
    receivers[14] = Receiver({ account: 0xE72185a9f4Ce3500d6dC7CCDCfC64cf66D823bE8, amount: 7539.922972149e18 });
    receivers[15] = Receiver({ account: 0x055a0495104AeA25551E7A58eBA88DC56709E871, amount: 7172.958049051e18 });
    receivers[16] = Receiver({ account: 0x6D74e589B0aDB2B1941E91D8CdA35DDB7B15F4ff, amount: 6504.447587124e18 });
    receivers[17] = Receiver({ account: 0x3F4ADba7BFA1806Cf3d0c067a20a9144205c4734, amount: 6155.053768304e18 });
    receivers[18] = Receiver({ account: 0xc086c0aBA8c41D507938c01dA7A6aF5E41F3942d, amount: 5610.195530258e18 });
    receivers[19] = Receiver({ account: 0xf567361ff0bCDcAd1252c8E2Fb8e5d4a9bB4e266, amount: 4235.523313649e18 });
    receivers[20] = Receiver({ account: 0x97F37E5cF02646A271DA888b6ab2A359B10059F0, amount: 3903.912251211e18 });
    receivers[21] = Receiver({ account: 0x25CFe43c0Ac31002A8a69072C9cbaB888703be19, amount: 3717.102327015e18 });
    receivers[22] = Receiver({ account: 0xCa81a029aCa50Fa3e25Ea2f26E10152d903fB4B5, amount: 2882.334764872e18 });
    receivers[23] = Receiver({ account: 0x70f6932BBCb1196973d81803279d1A6a2d77d533, amount: 2638.84130867e18 });
    receivers[24] = Receiver({ account: 0x666beEC52704Ab7c62A4Bb2c87B8A86c35B28a35, amount: 2617.071219989e18 });
    receivers[25] = Receiver({ account: 0x8935eCD450A97Bb995717Bc58EBAf2f69503a817, amount: 2494.92363188e18 });
    receivers[26] = Receiver({ account: 0x4ee0aa8D1189E04A448BE67F799e2e040De9EED2, amount: 2165.048326218e18 });
    receivers[27] = Receiver({ account: 0x93CEA50Fbce3B97146698E1e07F0B1AdA810bFd7, amount: 2145.606630586e18 });
    receivers[28] = Receiver({ account: 0xc506Bf5806cafA29e4bB35112fd616Fcd43707CA, amount: 2065.336664661e18 });
    receivers[29] = Receiver({ account: 0x1b242BD3532ff21F5C5DcBFFC95eBa13f2414D5B, amount: 1936.864664875e18 });
    receivers[30] = Receiver({ account: 0x08e166BDdc849CFd91084e828B5096085e8e0875, amount: 1878.58939084e18 });
    receivers[31] = Receiver({ account: 0x65AE0ed283fA71fd0d22f13512d7e0BD9E54c14A, amount: 1592.487263724e18 });
    receivers[32] = Receiver({ account: 0xb7c5897033b2158286B9C1Ca4E1cFbE48B8406af, amount: 1532.105174092e18 });
    receivers[33] = Receiver({ account: 0x0769cBf44073741cCb4C39c945402130B46fa8A7, amount: 1395.800284311e18 });
    receivers[34] = Receiver({ account: 0x7E8883a05C2e82dB78ed1240BFA4764cF7327169, amount: 1276.23448691e18 });
    receivers[35] = Receiver({ account: 0xdB7ceb52d7d88b0358f430f4E4Ef4e10bD55537B, amount: 1274.456240769e18 });
    receivers[36] = Receiver({ account: 0x55D5eaac765B4dA1a3BaE6C9987a5429Bcd79870, amount: 1061.442767499e18 });
    receivers[37] = Receiver({ account: 0x741AA7CFB2c7bF2A1E7D4dA2e3Df6a56cA4131F3, amount: 995.868011713e18 });
    receivers[38] = Receiver({ account: 0x618786F526812d6D09b977259C11E0A64D9A8741, amount: 945.436210699e18 });
    receivers[39] = Receiver({ account: 0xd5553C9726EA28e7EbEDfe9879cF8aB4d061dbf0, amount: 643.111387844e18 });
    receivers[40] = Receiver({ account: 0x6b71745596F2C19E87BEA5d5084fc55cb1d45a72, amount: 627.54532399e18 });
    receivers[41] = Receiver({ account: 0xC574aA8461195018cA1dfD6E9705e0d032e1077B, amount: 612.382740097e18 });
    receivers[42] = Receiver({ account: 0xE17Ab71916058cC7113b368f87C7A1F0e6F55Af3, amount: 546.971525794e18 });
    receivers[43] = Receiver({ account: 0x16d390c1cB334B1b06ce67AC230988dDDE90fc8f, amount: 512.823612426e18 });
    receivers[44] = Receiver({ account: 0x9aB8D84f6530e8aEf9d77C3adEBCD90698e61587, amount: 496.070399266e18 });
    receivers[45] = Receiver({ account: 0x26a5cE5620527599c143157954104e5bdFE5812f, amount: 441.484419303e18 });
    receivers[46] = Receiver({ account: 0x3cBde5D304a862B59F911a079b1f1E3a80DD6350, amount: 408.504968675e18 });
    receivers[47] = Receiver({ account: 0xFA1AcD28B296AC259cBB2d900224FD2522675cb5, amount: 389.75940647e18 });
    receivers[48] = Receiver({ account: 0x2839da03cE71177515ecD7F40e6E847dd497179C, amount: 326.581612887e18 });
    receivers[49] = Receiver({ account: 0xC75371e3c1fD9E0A215F597682ABe26DDcCFe4c6, amount: 306.630575474e18 });
    receivers[50] = Receiver({ account: 0xE13046ffB808D28B8b34A52E348afe30D1958F0D, amount: 280.100771108e18 });
    receivers[51] = Receiver({ account: 0x2483A0821b7852Cf3D251BE6C245746cC7eE9634, amount: 265.759955473e18 });
    receivers[52] = Receiver({ account: 0x21387a57A16186737599447802a3DAB57DF17C45, amount: 243.304450496e18 });
    receivers[53] = Receiver({ account: 0x94458AA887d18f85003c3B0391594767dDC733Fb, amount: 238.405997392e18 });
    receivers[54] = Receiver({ account: 0xE855a79c522226045BecE2fA6A446b04F2aC577F, amount: 220.036993863e18 });
    receivers[55] = Receiver({ account: 0x889CEF5559EB8b6a1dBCC445fB479e5530c37D8f, amount: 192.707415666e18 });
    receivers[56] = Receiver({ account: 0xbC1cFf59918AadCc2269a4114e6f51CB585e3292, amount: 177.231763813e18 });
    receivers[57] = Receiver({ account: 0x677Ffe1Ee372e4f6aF8b6583B0012289940e2324, amount: 170.794546617e18 });
    receivers[58] = Receiver({ account: 0x377a5053e1027E96d555A91A8997057fa27C5dC5, amount: 168.976670945e18 });
    receivers[59] = Receiver({ account: 0xAe289D2618CcFA247645Dd8e89326c91acEF62e0, amount: 164.029553493e18 });
    receivers[60] = Receiver({ account: 0x15fE8337a6E23629Fa09DC6e0F8b041D681ec995, amount: 160.843266075e18 });
    receivers[61] = Receiver({ account: 0x4fE01A9566bB47DCafB0FDa9363Aa00D3a6f45B3, amount: 160.415362556e18 });
    receivers[62] = Receiver({ account: 0xEc87Af7785E1f4aB42BE2d8401dbE1a16384f28a, amount: 149.298159269e18 });
    receivers[63] = Receiver({ account: 0xa765A629f11f538F6d67e3fDF799BaEd1506017d, amount: 146.601891785e18 });
    receivers[64] = Receiver({ account: 0xd3d5458C07B655Cd79d4814A52f42EB8Fc59c24c, amount: 135.745190839e18 });
    receivers[65] = Receiver({ account: 0x7385f8b5ab1303C8E476d371973DB768F1a43Bb4, amount: 132.185239956e18 });
    receivers[66] = Receiver({ account: 0x5E303627181a51bced34A92ABf6F1a77d8E97587, amount: 114.379785293e18 });
    receivers[67] = Receiver({ account: 0xBD4cccC9B987455f268c223549ed99e2711650cF, amount: 97.413626348e18 });
    receivers[68] = Receiver({ account: 0x7aD502764EEc17DE82f5C6bfdc70ceEde354a180, amount: 95.029472382e18 });
    receivers[69] = Receiver({ account: 0xA3eCa96A73f50CaA8aaccC117E24ef8097117ff3, amount: 85.450649157e18 });
    receivers[70] = Receiver({ account: 0xD47D6Efd56c45C6CdAc436e6A96bE732079cf669, amount: 82.868695342e18 });
    receivers[71] = Receiver({ account: 0x55991f0c684920D08DF05af1eabD202113DA2a9e, amount: 75.641516657e18 });
    receivers[72] = Receiver({ account: 0xdD83eaa1A66369AB09B2642a1A130287c4aD8e40, amount: 67.384602465e18 });
    receivers[73] = Receiver({ account: 0x14335CE04DF0B601A3bdC1d16d9537067f49C845, amount: 64.302747903e18 });
    receivers[74] = Receiver({ account: 0xCA038A19D1C9473E3adbB2b95328bbD4393B176c, amount: 64.283720873e18 });
    receivers[75] = Receiver({ account: 0x62354252BC6EDDe709FaA6B3a7D1CBd792C6fA52, amount: 63.583375879e18 });
    receivers[76] = Receiver({ account: 0x89dD24AAf3223B1B9738c0920F3c6E5c2C28606c, amount: 59.848208597e18 });
    receivers[77] = Receiver({ account: 0xa434187047120684940f946F367Ba9a16dB11b4c, amount: 58.658168424e18 });
    receivers[78] = Receiver({ account: 0x67D0a091F1F4c9e6A9b50ce4Eaf203c9Fc488Ca3, amount: 58.356521904e18 });
    receivers[79] = Receiver({ account: 0xD670a99b9ad6b9FE256294f51cFE5F38E51D54Aa, amount: 52.960249281e18 });
    receivers[80] = Receiver({ account: 0xAEd4DB9b9BBC7a8e4a7aA1cE6F474dde154356A2, amount: 51.053060737e18 });
    receivers[81] = Receiver({ account: 0x5e1598d8eA0f7C508840FC4aBfe33a6638F8672C, amount: 49.837472931e18 });
    receivers[82] = Receiver({ account: 0x601Fc8BE66979183ad2Bc77ed58610F9a580C9b5, amount: 43.760077469e18 });
    receivers[83] = Receiver({ account: 0x93400847bbF509BD43bCC2EE94C773008A6Cc0b5, amount: 38.934595886e18 });
    receivers[84] = Receiver({ account: 0x97405030cA47983E7E0F07a32FF3362A567f3724, amount: 37.328049291e18 });
    receivers[85] = Receiver({ account: 0x7C6Accd51cbbdd53354De581841803b4f79d48e7, amount: 37.284259049e18 });
    receivers[86] = Receiver({ account: 0xbBf15e008535cB93A7e2168038DC316c56faf791, amount: 32.930761071e18 });
    receivers[87] = Receiver({ account: 0xb4736E0661Bb14632633F40af02f397323475a62, amount: 32.426147949e18 });
    receivers[88] = Receiver({ account: 0xf2d764Be88b1be12FF2F8Bfc23Dca65830559496, amount: 32.180723026e18 });
    receivers[89] = Receiver({ account: 0x3630Ab305635199133315097b31099A44ee13497, amount: 29.333961815e18 });
    receivers[90] = Receiver({ account: 0xE1AB85E458ebEA43c5302CE84f5a89Cb22fE351a, amount: 27.75470883e18 });
    receivers[91] = Receiver({ account: 0x000000000A38444e0a6E37d3b630d7e855a7cb13, amount: 24.514123004e18 });
    receivers[92] = Receiver({ account: 0x45f4998F4FE2535a575e807DD2Ea84dfBEA44038, amount: 24.218484778e18 });
    receivers[93] = Receiver({ account: 0x1e017aBD4C0597Bf854C6361E3f2C975104167e7, amount: 22.952370326e18 });
    receivers[94] = Receiver({ account: 0x530514e17A9da448E69690247906668695b47dF8, amount: 17.594242001e18 });
    receivers[95] = Receiver({ account: 0x7d5Ff8caE8eF8d15357Cfd4A291E830C0F875F1B, amount: 16.455279153e18 });
    receivers[96] = Receiver({ account: 0xF8997d911a7ac579a93b962e08FDca2CAffa2A93, amount: 16.393713906e18 });
    receivers[97] = Receiver({ account: 0x3E9C43f09834250b7623058B3369C9209221280B, amount: 15.40586153e18 });
    receivers[98] = Receiver({ account: 0x5353D57398A1d5cC3f715Df0a365d4b5F2A4044B, amount: 14.116518547e18 });
    receivers[99] = Receiver({ account: 0x3E5d4D9867aFD50D1Febf5daD725DAF45392Ae0B, amount: 11.927606769e18 });
    receivers[100] = Receiver({ account: 0xE14a13b8eB93B6569a748EA57A1A97025fc82BE9, amount: 10.278866351e18 });
    receivers[101] = Receiver({ account: 0xe9A5D492552c5e493C08910f3eFF4E61C79CD0B4, amount: 9.042311069e18 });
    receivers[102] = Receiver({ account: 0xb79F0aC2Ff554612B67f2699d577de95afe0692C, amount: 8.681649058e18 });
    receivers[103] = Receiver({ account: 0xd946B3A3694864358DcA0CD641d72263E032a0c8, amount: 8.114894542e18 });
    receivers[104] = Receiver({ account: 0xF6bd3EAd16511554485fD4987ee4b5163102C6fE, amount: 7.997829135e18 });
    receivers[105] = Receiver({ account: 0xC6510245a3d961746DB4883916d2D600e19f4ff3, amount: 6.363107872e18 });
    receivers[106] = Receiver({ account: 0xE97fb20e1399565AF7aa315ED0A512B2969247a4, amount: 4.919388233e18 });
    receivers[107] = Receiver({ account: 0xc1404944d1b07A579c63999EF851dA87879B75d7, amount: 4.508274819e18 });
    receivers[108] = Receiver({ account: 0x88CE43b0C597db8D669dbD75613210AbBa416bc9, amount: 3.889997178e18 });
    receivers[109] = Receiver({ account: 0x1e50Fe160EF96397802403Be50CA6179810050e5, amount: 3.690371922e18 });
    receivers[110] = Receiver({ account: 0x436638D42bA6b9D971e3B99cfD1BC2A27508777A, amount: 3.365155959e18 });
    receivers[111] = Receiver({ account: 0xdD837FaE8FE802972901215ac2aCC550C3998a54, amount: 3.014103777e18 });
    receivers[112] = Receiver({ account: 0xD21F7897F8329CDa66a9Acd67162C8fC665528DD, amount: 2.861444526e18 });
    receivers[113] = Receiver({ account: 0x6A9ee69B6781C18164ee9F7C58f1763BcFfC7c51, amount: 2.298150235e18 });
    receivers[114] = Receiver({ account: 0x5ADEFa6B4c1e343C82C9f2C683918101873FBA78, amount: 2.106653257e18 });
    receivers[115] = Receiver({ account: 0xB0F0bba5f8Daaa46185e2B476e4f42be853E710a, amount: 1.698075327e18 });
    receivers[116] = Receiver({ account: 0x2D42d6bB3d18A7be35D76b599aee9D3358b22B3E, amount: 1.428687095e18 });

    vm.startBroadcast(0xe61Bdef3FFF4C3CF7A07996DCB8802b5C85B665a); // deployer
    timelock.schedule(exa, 0, abi.encodeCall(IERC20.approve, (sablier, 1_000_000e18)), 0, 0, 24 hours);
    for (uint256 i = 0; i < receivers.length; ++i) {
      timelock.schedule(
        sablier,
        0,
        abi.encodeCall(
          ISablierV2LockupLinear.createWithRange,
          (
            CreateWithRange({
              asset: exa,
              sender: SENDER,
              recipient: receivers[i].account,
              totalAmount: receivers[i].amount,
              cancelable: true,
              range: Range({ start: START_DATE, cliff: START_DATE, end: START_DATE + DURATION }),
              broker: Broker({ account: address(0), fee: 0 })
            })
          )
        ),
        0,
        0,
        24 hours
      );
    }
    vm.stopBroadcast();

    if (vm.envOr("SCRIPT_SIMULATE", false)) {
      vm.warp(block.timestamp + 24 hours);
      uint256 balance = IERC20(exa).balanceOf(address(timelock));

      vm.startBroadcast(SENDER);
      timelock.execute(exa, 0, abi.encodeCall(IERC20.approve, (sablier, 1_000_000e18)), 0, 0);
      for (uint256 i = 0; i < receivers.length; ++i) {
        timelock.execute(
          sablier,
          0,
          abi.encodeCall(
            ISablierV2LockupLinear.createWithRange,
            (
              CreateWithRange({
                asset: exa,
                sender: SENDER,
                recipient: receivers[i].account,
                totalAmount: receivers[i].amount,
                cancelable: true,
                range: Range({ start: START_DATE, cliff: START_DATE, end: START_DATE + DURATION }),
                broker: Broker({ account: address(0), fee: 0 })
              })
            )
          ),
          0,
          0
        );
      }
      vm.stopBroadcast();

      assert(IERC20(exa).balanceOf(address(timelock)) == balance - 1_000_000e18);
    }
  }
}

interface ISablierV2LockupLinear {
  function createWithRange(CreateWithRange calldata params) external returns (uint256 streamId);
}

struct Receiver {
  address account;
  uint128 amount;
}

struct CreateWithRange {
  address sender;
  address recipient;
  uint128 totalAmount;
  address asset;
  bool cancelable;
  Range range;
  Broker broker;
}

struct Range {
  uint40 start;
  uint40 cliff;
  uint40 end;
}

struct Broker {
  address account;
  uint256 fee;
}
