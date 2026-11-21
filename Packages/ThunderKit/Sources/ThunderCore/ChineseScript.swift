import Foundation

/// 檢查中文裡有沒有簡體字。
///
/// 用來把關文字模型的輸出：提示已經要求台灣繁體，這裡是最後一道檢查，發現簡體字就重試一次。
/// 清單只收「只在簡體出現、台灣繁體文章不會用到」的常用字，寧可漏抓也不要誤判
/// （例如 `里`、`后`、`干`、`只`、`台` 在繁體裡也是正常的字，所以不在清單裡）。
/// 中國大陸用語（字是繁體、但詞不是台灣的說法）的檢查是 M4 的工作，不在這裡。
public enum ChineseScript {
    /// `text` 裡有沒有簡體字。
    public static func containsSimplified(_ text: String) -> Bool {
        text.unicodeScalars.contains { simplifiedOnly.contains($0) }
    }

    /// `text` 裡出現的簡體字（依出現順序，不重複）。
    public static func simplifiedCharacters(in text: String) -> [Character] {
        var seen: Set<Unicode.Scalar> = []
        var result: [Character] = []
        for scalar in text.unicodeScalars where simplifiedOnly.contains(scalar) && seen.insert(scalar).inserted {
            result.append(Character(scalar))
        }
        return result
    }

    private static let simplifiedOnly: Set<Unicode.Scalar> = Set(
        """
        这们为说时个会国过对发现经开关还进动样应实学问题点机电话长两门间见让给认识请语读课该讲谢议论设许试调谈证评译词误记计访详诉\
        负责费资质购贸赛较输转软轻载连远适选递邮钱银错键镜闻阅队阳阶际陆险随难须顶项顺预领频颜风飞饭馆马验鱼鸟齐龙务业东丝严丧丰\
        临丽举义乌乐习乡书买乱争亏亚产亲亿仅从仓仪价众优传伤伦伪侦侧储儿兰兴养军农决况净减凤凭击刘则刚创删剂剑剧劝办励劲劳势华\
        协单卖卫厅历厉压厌县参双变叙叠号叹吓吗员响团园围图圆圣场坏块坚坛处备复够头夺奋奖妇妈孙宁宝宠审宪宫宽宾寻导寿将尔尘尝层属\
        岁岛币帅师带帮库废异弃张弥弯弹强归当录彻忆忧怀态总恋恶惊惧惨惯愤戏战执扩扫扬扰护报担拟拥择挂挡挤挥损摄摆摇敌数断无\
        旧显晓暂杀杂权条来杨极构枪标栏树档桥梦检楼横欢欧残毁毕气汉汤沟泽洁浅济涨渐渔湾湿满潜灭灯灵灾炉炼烂烦烧热爱爷牵状犹独狭猎\
        猪猫献环画畅疗疯盐监盖盘矿码砖确础碍祸离积称稳穷窃竞笔筑简类粮纠红纤约级纪纯纲纳纵纷纸纹纺线练组细织终绍绑结绕绘络绝统继\
        绩绪续维绵综缓编缘缩网罗罚罢联聪肃肠肤胁胜脉脏脑脱腾舰艰艺节苏荐荡荣药莱萨蓝虑虚蚀补衬袭装观规视览觉触誉讨训讯讳讶诈诗诚\
        诞诸诺谁谅谊谋谎谜谣谦谨谱贝贡财贤败账货贩贪贫贯贱贴贵贷贺贼赁赋赌赏赐赔赖赚赞赠赵趋跃践踪车轨轮轰辅辆辈辉辑辖辞辩边达迁\
        迈运违迟逊逻遗邓邻郑酱释针钉钓钢钥钦钩钮钻铁铃铅铜铝铺链销锁锅锋锦镇闪闭闯闲闷闹阀阁阴阵陈隐隶雏雾静韩页顽顾顿颗额飘饥\
        饮饰饱驱驳驻驾骂骑骗骤鲁鲜鸡鸣鸭鸿麦齿龟么
        """.unicodeScalars.filter { $0.value > 0x2E7F })
}
