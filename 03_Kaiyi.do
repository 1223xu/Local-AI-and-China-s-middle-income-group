clear all
set more off
set linesize 255

*============================= 暂命名数据文件，需修改文件名 =======================*
global ROOT     "C:\Users\Administrator\Desktop\修改\数据"                 
global MAP_FILE "C:\Users\Administrator\Desktop\修改\数据\顺序码匹配.dta"      
*=============================================================================*



global CFPS_FILE   "$ROOT/01_cfps_household_2012_2022.dta"
global CITY_FILE   "$ROOT/02_city_ai_panel_2012_2022.dta"
global OUT         "$ROOT/results"
global MASTER_FILE "$ROOT/onsite_analysis_master.dta"



capture mkdir "$OUT"
capture log close
log using "$OUT/Kaiyi_full_analysis.log", text replace

preserve
keep if sample_main
keep city year grt_inv_full_d_l1
bysort city year: keep if _n==1
summarize grt_inv_full_d_l1, detail
local ai_p1  = r(p1)
local ai_p99 = r(p99)
restore

generate double ai = min(max(grt_inv_full_d_l1,`ai_p1'),`ai_p99') if grt_inv_full_d_l1<.
label variable ai "AI exposure"


* 统一变量口径
global Y             mid_income
global AI_MAIN       ai
global AI_FIRM       ai_firm_cum_d_l1
global IV_MAIN       iv_bartik_8505
global CITYSIZE      city_size4
global WEIGHT        hh_weight_cs_norm

global HH_CONTROLS   "resp_age resp_age2 resp_male resp_ever_married resp_urban_hukou resp_educ_years resp_health_good5 hhsize_official child_ratio older_ratio"
global HH_NO_HUKOU   "resp_age resp_age2 resp_male resp_ever_married resp_educ_years resp_health_good5 hhsize_official child_ratio older_ratio"
global CITY_CONTROLS "ln_gdp_pc tertiary_secondary gov_exp_gdp univ_per10k"
global CITY_NO_IND   "ln_gdp_pc gov_exp_gdp univ_per10k"
global FULL_CONTROLS "$HH_CONTROLS $CITY_CONTROLS"


********************************************************************************
* 0. 现场地理匹配与分析主数据
********************************************************************************

use "$CFPS_FILE", clear
isid year fid
count
local n_raw = r(N)

* 第一步：CFPS区县顺序码 -> 六位区县行政代码
merge m:1 countyid using "$MAP_FILE", keepusing(code) generate(_merge_geo)
drop if _merge_geo == 2
generate byte matched_geo = (_merge_geo == 3)
drop _merge_geo


* 第二步：标记该城市-年份是否存在于城市-AI面板
preserve
use "$CITY_FILE", clear
keep year city
duplicates drop
generate byte in_citypanel = 1
tempfile citykeys
save `citykeys', replace
restore
merge m:1 year city using `citykeys', keep(1 3) nogen
replace in_citypanel = 0 if in_citypanel == .
generate byte matched_city = (matched_geo == 1 & in_citypanel == 1)

*---------------------- 匹配率诊断（结果落 $OUT/Diag_*）----------------------*
preserve
collapse (count) n_raw = fid (sum) n_geo = matched_geo n_city = matched_city, by(year)
generate double rate_geo  = n_geo/n_raw
generate double rate_city = n_city/n_raw
label variable n_geo   "countyid匹配上码表的观测数"
label variable n_city  "两步均匹配（进入分析）的观测数"
display as text "【诊断】各年匹配率（rate_geo=码表匹配率；rate_city=两步累计保留率）"
list year n_raw n_geo rate_geo n_city rate_city, clean noobs
export delimited using "$OUT/Diag_match_rate_by_year.csv", replace
restore

count if matched_geo
local n_geo_all = r(N)
count if matched_city
local n_city_all = r(N)
display as text "【诊断】合计：原始 `n_raw' 户次；码表匹配 `n_geo_all'；进入分析 `n_city_all'"

* 未匹配清单：码表缺失的 countyid、城市面板缺失的地级市
preserve
keep if matched_geo == 0
contract year countyid
gsort -_freq
export delimited using "$OUT/Diag_unmatched_countyid.csv", replace
restore

preserve
keep if matched_geo == 1 & in_citypanel == 0
contract year city
gsort -_freq
export delimited using "$OUT/Diag_unmatched_city.csv", replace
restore
*---------------------------------------------------------------------------*

keep if matched_city == 1
drop matched_geo matched_city in_citypanel

* 并入城市-AI面板变量（上一步已保证全部匹配）
merge m:1 year city using "$CITY_FILE", generate(_merge_city)
assert _merge_city != 1
keep if _merge_city == 3
drop _merge_city
isid year fid


* 家庭控制变量
generate double resp_age2   = resp_age^2 if resp_age < .
generate double child_ratio = child_u16_count/hhsize_official if hhsize_official > 0
generate double older_ratio = older_60plus_count/hhsize_official if hhsize_official > 0
generate byte prov_code     = floor(city/10000)

label variable resp_age2   "Finance respondent age squared"
label variable child_ratio "Share of family members younger than 16"
label variable older_ratio "Share of family members age 60 or older"
label variable prov_code   "Province code derived from standard city code"

* 各表样本标记
egen __miss_t2c1 = rowmiss($Y $AI_MAIN)
generate byte sample_t2c1 = (__miss_t2c1==0 & $WEIGHT>0 & $WEIGHT<.)
egen __miss_t2c2 = rowmiss($Y $AI_MAIN $HH_CONTROLS)
generate byte sample_t2c2 = (__miss_t2c2==0 & $WEIGHT>0 & $WEIGHT<.)
egen __miss_cov = rowmiss($Y $FULL_CONTROLS)
generate byte sample_covars = (__miss_cov==0 & $WEIGHT>0 & $WEIGHT<.)
generate byte sample_main = (sample_covars==1 & $AI_MAIN<.)
drop __miss_t2c1 __miss_t2c2 __miss_cov

* 固定的2020年城市规模分类应在同一城市内跨期不变。
assert inrange($CITYSIZE,1,4) if sample_main
bysort city (year): assert $CITYSIZE==$CITYSIZE[1] if $CITYSIZE<.
tabulate $CITYSIZE if sample_main

compress
save "$MASTER_FILE", replace


********************************************************************************
* Table 1. 加权描述性统计
********************************************************************************

use "$MASTER_FILE", clear
global DESC_VARS "$Y $AI_MAIN $AI_FIRM resp_age resp_age2 resp_male resp_ever_married resp_urban_hukou resp_educ_years resp_health_good5 hhsize_official child_ratio older_ratio ln_gdp_pc tertiary_secondary gov_exp_gdp univ_per10k"

tabstat $DESC_VARS if sample_main [aweight=$WEIGHT], ///
    statistics(n mean sd min p50 max) columns(statistics) save
matrix Table1 = r(StatTotal)'
putexcel set "$OUT/Table1_weighted_descriptives.xlsx", replace
putexcel A1=matrix(Table1), names

********************************************************************************
* Table 2. 基准回归
********************************************************************************

use "$MASTER_FILE", clear

areg $Y $AI_MAIN i.year if sample_t2c1 [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table2_baseline.doc", word replace ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("(1) AI + FE") ///
    addtext(Household controls, NO, City controls, NO, City FE, YES, Year FE, YES)

areg $Y $AI_MAIN $HH_CONTROLS i.year if sample_t2c2 [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table2_baseline.doc", word append ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("(2) + Household") ///
    addtext(Household controls, YES, City controls, NO, City FE, YES, Year FE, YES)

regress $Y $AI_MAIN $FULL_CONTROLS if sample_main [pweight=$WEIGHT], ///
    vce(cluster city)
outreg2 using "$OUT/Table2_baseline.doc", word append ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("(3) Full, no FE") ///
    addtext(Household controls, YES, City controls, YES, City FE, NO, Year FE, NO)

areg $Y $AI_MAIN $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table2_baseline.doc", word append ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("(4) Preferred") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

********************************************************************************
* Table 3. 收入组转移（原期权重；目的期AI、控制与固定效应）
********************************************************************************

use "$MASTER_FILE", clear
tempfile destination origin
save `destination', replace

use "$CFPS_FILE", clear
keep year fid income_group3_real2018 $WEIGHT
rename income_group3_real2018 origin_group
rename $WEIGHT origin_weight
replace year = year + 2
keep if inlist(year,2014,2016,2018,2020,2022)
isid year fid
save `origin', replace

use `destination', clear
merge 1:1 year fid using `origin', keep(3) nogen
generate byte to_low    = (income_group3_real2018==1) if income_group3_real2018<.
generate byte to_middle = (income_group3_real2018==2) if income_group3_real2018<.
generate byte to_high   = (income_group3_real2018==3) if income_group3_real2018<.

local table3_mode replace
forvalues o=1/3 {
    foreach d in low middle high {
        areg to_`d' $AI_MAIN $FULL_CONTROLS i.year ///
            if origin_group==`o' & origin_weight>0 & origin_weight<. ///
            [pweight=origin_weight], absorb(city) vce(cluster city)
        outreg2 using "$OUT/Table3_income_transitions.doc", word `table3_mode' ///
            keep($AI_MAIN) se bdec(5) sdec(5) ctitle("Origin`o'_to_`d'") ///
            addtext(Origin-wave weight, YES, City FE, YES, Year FE, YES)
        local table3_mode append
    }
}

********************************************************************************
* Table 4. Bartik-style工具变量：第一阶段、简约式与2SLS
********************************************************************************

use "$MASTER_FILE", clear
generate byte sample_iv = (sample_main==1 & $IV_MAIN<.)

areg $AI_MAIN $IV_MAIN $FULL_CONTROLS i.year if sample_iv ///
    [pweight=$WEIGHT], absorb(city) vce(cluster city)
test $IV_MAIN
local firstF = r(F)
outreg2 using "$OUT/Table4_IV_main.doc", word replace ///
    keep($IV_MAIN) se bdec(5) sdec(5) ctitle("(1) First stage") ///
    addstat(Excluded-IV F, `firstF') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

areg $Y $AI_MAIN $FULL_CONTROLS i.year if sample_iv ///
    [pweight=$WEIGHT], absorb(city) vce(cluster city)
outreg2 using "$OUT/Table4_IV_main.doc", word append ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("(2) Same-sample OLS") ///
    addstat(Excluded-IV F, `firstF') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

areg $Y $IV_MAIN $FULL_CONTROLS i.year if sample_iv ///
    [pweight=$WEIGHT], absorb(city) vce(cluster city)
outreg2 using "$OUT/Table4_IV_main.doc", word append ///
    keep($IV_MAIN) se bdec(5) sdec(5) ctitle("(3) Reduced form") ///
    addstat(Excluded-IV F, `firstF') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

ivregress 2sls $Y $FULL_CONTROLS i.year i.city ///
    ($AI_MAIN=$IV_MAIN) if sample_iv [pweight=$WEIGHT], ///
    vce(cluster city) small
outreg2 using "$OUT/Table4_IV_main.doc", word append ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("(4) 2SLS") ///
    addstat(Excluded-IV F, `firstF') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* 不同历史暴露窗口的敏感性（主窗口8505排第一列）
local table4b_mode replace
foreach z in iv_bartik_8505 iv_bartik_8500 iv_bartik_9505 iv_bartik_0010 {
    quietly areg $AI_MAIN `z' $FULL_CONTROLS i.year ///
        if sample_main & `z'<. [pweight=$WEIGHT], ///
        absorb(city) vce(cluster city)
    quietly test `z'
    local zF = r(F)
    ivregress 2sls $Y $FULL_CONTROLS i.year i.city ///
        ($AI_MAIN=`z') if sample_main & `z'<. [pweight=$WEIGHT], ///
        vce(cluster city) small
    outreg2 using "$OUT/Table4B_IV_windows.doc", word `table4b_mode' ///
        keep($AI_MAIN) se bdec(5) sdec(5) ctitle("`z'") ///
        addstat(Excluded-IV F, `zF') ///
        addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)
    local table4b_mode append
}

********************************************************************************
* Table 5A. 替代AI指标
* 第一列为截至t-1、从2000年起累计注册的AI企业数，以1000家为单位。
********************************************************************************

use "$MASTER_FILE", clear
generate double ai_alt = $AI_FIRM
label variable ai_alt "Alternative local AI development measure"

local table5a_mode replace
local table5a_vars "$AI_FIRM grt_inv_full_d_t grt_inv_frac_d_l1 grt_all_full_d_l1 app_inv_full_d_l1 pub_inv_full_d_l1"
foreach x of local table5a_vars {
    local ttl "`x'"
    if "`x'"=="$AI_FIRM"            local ttl "Cumulative AI firms (000s, t-1)"
    if "`x'"=="grt_inv_full_d_t"     local ttl "Same-year invention grants"
    if "`x'"=="grt_inv_frac_d_l1"    local ttl "Lagged fractional grants"
    if "`x'"=="grt_all_full_d_l1"    local ttl "Lagged all-patent grants"
    if "`x'"=="app_inv_full_d_l1"    local ttl "Lagged invention applications"
    if "`x'"=="pub_inv_full_d_l1"    local ttl "Lagged invention publications"
    replace ai_alt = `x'
    if "`x'"=="$AI_FIRM" replace ai_alt = `x'/1000
    areg $Y ai_alt $FULL_CONTROLS i.year ///
        if sample_main & ai_alt<. [pweight=$WEIGHT], ///
        absorb(city) vce(cluster city)
    outreg2 using "$OUT/Table5A_AI_measurement.doc", word `table5a_mode' ///
        keep(ai_alt) se bdec(5) sdec(5) ctitle("`ttl'") ///
        addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)
    local table5a_mode append
}

********************************************************************************
* Table 5B. 其他稳健性
********************************************************************************

use "$MASTER_FILE", clear

* 表注所需：本表第4列的省份数（outreg2的addnote仅在首次replace调用时生效，故需提前取数）
quietly levelsof prov_code if sample_main, local(provlist)
local n_prov : word count `provlist'
preserve
keep if sample_main
keep city year $AI_MAIN
bysort city year: keep if _n==1
summarize $AI_MAIN, detail
local ai_p1  = r(p1)
local ai_p99 = r(p99)
restore

generate double ai_test = min(max($AI_MAIN,`ai_p1'),`ai_p99') if $AI_MAIN<.
label variable ai_test "AI exposure used in robustness specification"

areg $Y ai_test $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table5B_other_robustness.doc", word replace ///
    keep(ai_test) se bdec(5) sdec(5) ctitle("Winsor 1/99") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES) ///
    addnote("注：第4列同时纳入城市固定效应与省份×年份固定效应。城市固定效应已吸收省份维度，", ///
            "故每个省份有一个省份×年份虚拟变量因共线被自动剔除（本次运行共剔除 `n_prov' 个），", ///
            "该处理不影响人工智能技术系数及其标准误的估计。")

replace ai_test = $AI_MAIN
areg $Y ai_test $FULL_CONTROLS i.year ///
    if sample_main & $CITYSIZE!=1 [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table5B_other_robustness.doc", word append ///
    keep(ai_test) se bdec(5) sdec(5) ctitle("Exclude cities >=10m") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

areg $Y ai_test $FULL_CONTROLS i.year ///
    if sample_main & resp_age<=65 [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table5B_other_robustness.doc", word append ///
    keep(ai_test) se bdec(5) sdec(5) ctitle("Age <= 65") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

egen long province_year = group(prov_code year)
areg $Y ai_test $FULL_CONTROLS i.province_year if sample_main ///
    [pweight=$WEIGHT], absorb(city) vce(cluster city)
* 城市固定效应已吸收省份，故每个省份必有一个省份×年份虚拟变量与之共线被剔除
quietly levelsof prov_code if e(sample), local(provlist)
local n_prov : word count `provlist'
display as text "【说明】省份×年份固定效应与absorb(city)部分共线，" ///
    "每省一个虚拟变量被自动剔除，共 `n_prov' 个，不影响AI系数与标准误。"
outreg2 using "$OUT/Table5B_other_robustness.doc", word append ///
    keep(ai_test) se bdec(5) sdec(5) ctitle("Province x year FE") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Province-year FE, YES)

areg $Y ai_test $FULL_CONTROLS i.year if sample_main, ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table5B_other_robustness.doc", word append ///
    keep(ai_test) se bdec(5) sdec(5) ctitle("Unweighted") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* 与“排除高收入家庭”定义相对应的附加敏感性列。
areg mid_income_nonhigh ai_test $FULL_CONTROLS i.year ///
    if sample_covars & nonhigh_income_sample==1 [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table5B_other_robustness.doc", word append ///
    keep(ai_test) se bdec(5) sdec(5) ctitle("Exclude high-income") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

********************************************************************************
* Table 5C. 核心解释变量函数形式敏感性
* AI专利密度原始偏度约10、峰度约136（约17%的城市—年份取零值），故检验水平值、
* asinh、ln(1+x)与缩尾四种设定。四种变换均为单调变换、不改变缺失结构，
* 因此四列样本完全一致（sample_main），但量纲不同，横向比较须看「Effect of 1 SD」。
********************************************************************************

use "$MASTER_FILE", clear

* 缩尾分位点在唯一城市—年份层面计算，不按家庭重复频数取分位数
preserve
keep if sample_main
keep city year $AI_MAIN
bysort city year: keep if _n==1
summarize $AI_MAIN, detail
local ai_p1  = r(p1)
local ai_p99 = r(p99)
restore

generate double ai_raw    = $AI_MAIN                            if $AI_MAIN<.
generate double ai_asinh  = asinh($AI_MAIN)                     if $AI_MAIN<.
generate double ai_ln1p   = ln(1+$AI_MAIN)                      if $AI_MAIN<.
generate double ai_winsor = min(max($AI_MAIN,`ai_p1'),`ai_p99') if $AI_MAIN<.
label variable ai_raw    "AI patent density, raw"
label variable ai_asinh  "asinh(AI patent density)"
label variable ai_ln1p   "ln(1 + AI patent density)"
label variable ai_winsor "AI patent density, winsorized 1/99 (city-year)"

* (1) 水平值：与Table 2第(4)列同规格，作为对照基准
areg $Y ai_raw $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
local b1 = _b[ai_raw]
quietly summarize ai_raw if e(sample) [aweight=$WEIGHT]
local sd1 = r(sd)
local e1  = `b1'*`sd1'
outreg2 using "$OUT/Table5C_AI_functional_form.doc", word replace ///
    keep(ai_raw) se bdec(5) sdec(5) ctitle("(1) Raw density") ///
    addstat(SD of regressor, `sd1', Effect of 1 SD, `e1') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES) ///
    addnote("注：因变量为是否属于中等收入群体。四列样本一致（同为sample_main），", ///
            "四种变换均为单调变换、不改变缺失结构，故观测数完全相同。", ///
            "各列自变量量纲不同，系数不可直接横向比较，应比较「Effect of 1 SD」一行，", ///
            "即自变量变动一个加权标准差所对应的中等收入概率变动。", ///
            "缩尾分位点在唯一城市—年份层面计算，不按家庭重复频数取分位数。")

* (2) asinh：可处理零值的近对数变换
areg $Y ai_asinh $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
local b2 = _b[ai_asinh]
quietly summarize ai_asinh if e(sample) [aweight=$WEIGHT]
local sd2 = r(sd)
local e2  = `b2'*`sd2'
outreg2 using "$OUT/Table5C_AI_functional_form.doc", word append ///
    keep(ai_asinh) se bdec(5) sdec(5) ctitle("(2) asinh(AI)") ///
    addstat(SD of regressor, `sd2', Effect of 1 SD, `e2') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (3) ln(1+x)
areg $Y ai_ln1p $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
local b3 = _b[ai_ln1p]
quietly summarize ai_ln1p if e(sample) [aweight=$WEIGHT]
local sd3 = r(sd)
local e3  = `b3'*`sd3'
outreg2 using "$OUT/Table5C_AI_functional_form.doc", word append ///
    keep(ai_ln1p) se bdec(5) sdec(5) ctitle("(3) ln(1+AI)") ///
    addstat(SD of regressor, `sd3', Effect of 1 SD, `e3') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (4) 城市—年份层面1%/99%缩尾
areg $Y ai_winsor $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
local b4 = _b[ai_winsor]
quietly summarize ai_winsor if e(sample) [aweight=$WEIGHT]
local sd4 = r(sd)
local e4  = `b4'*`sd4'
outreg2 using "$OUT/Table5C_AI_functional_form.doc", word append ///
    keep(ai_winsor) se bdec(5) sdec(5) ctitle("(4) Winsor 1/99") ///
    addstat(SD of regressor, `sd4', Effect of 1 SD, `e4') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

display as text "【Table5C】一个加权标准差对应的中等收入概率变动（四种函数形式）："
display as text "  (1) 水平值   系数=" %9.5f `b1' "  SD=" %8.4f `sd1' "  1SD效应=" %9.5f `e1'
display as text "  (2) asinh    系数=" %9.5f `b2' "  SD=" %8.4f `sd2' "  1SD效应=" %9.5f `e2'
display as text "  (3) ln(1+x)  系数=" %9.5f `b3' "  SD=" %8.4f `sd3' "  1SD效应=" %9.5f `e3'
display as text "  (4) 缩尾     系数=" %9.5f `b4' "  SD=" %8.4f `sd4' "  1SD效应=" %9.5f `e4'
********************************************************************************

use "$MASTER_FILE", clear

foreach s in wage business property {
    generate byte receive_`s' = (income_`s'_real2018>0) if income_`s'_real2018<.
    generate double ihs_`s' = asinh(income_`s'_real2018) if income_`s'_real2018<.
    generate double ln_`s'_positive = ln(income_`s'_real2018) if income_`s'_real2018>0 & income_`s'_real2018<.
}

local table6_mode replace
foreach y in receive_wage ihs_wage ln_wage_positive ///
             receive_business ihs_business ln_business_positive ///
             receive_property ihs_property ln_property_positive {
    areg `y' $AI_MAIN $FULL_CONTROLS i.year ///
        if sample_covars & $AI_MAIN<. & `y'<. [pweight=$WEIGHT], ///
        absorb(city) vce(cluster city)
    outreg2 using "$OUT/Table6_income_sources.doc", word `table6_mode' ///
        keep($AI_MAIN) se bdec(5) sdec(5) ctitle("`y'") ///
        addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)
    local table6_mode append
}

********************************************************************************
* Table 6. 工资、经营与财产收入：广延边际、IHS、正收入样本
********************************************************************************

use "$MASTER_FILE", clear

foreach s in wage business property {
    generate byte receive_`s' = (income_`s'_real2018>0) if income_`s'_real2018<.
    generate double ihs_`s' = asinh(income_`s'_real2018) if income_`s'_real2018<.
    generate double ln_`s'_positive = ln(income_`s'_real2018) if income_`s'_real2018>0 & income_`s'_real2018<.
}

local table6_mode replace
foreach y in receive_wage ihs_wage ln_wage_positive ///
             receive_business ihs_business ln_business_positive ///
             receive_property ihs_property ln_property_positive {
    areg `y' $AI_MAIN $FULL_CONTROLS i.year ///
        if sample_covars & $AI_MAIN<. & `y'<. [pweight=$WEIGHT], ///
        absorb(city) vce(cluster city)
    outreg2 using "$OUT/Table6_income_sources.doc", word `table6_mode' ///
        keep($AI_MAIN) se bdec(5) sdec(5) ctitle("`y'") ///
        addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)
    local table6_mode append
}

********************************************************************************
* Table 7A. 财务回答人户口异质性：分样本 + 正式交互检验
********************************************************************************

use "$MASTER_FILE", clear

areg $Y $AI_MAIN $HH_NO_HUKOU $CITY_CONTROLS i.year ///
    if sample_main & resp_urban_hukou==0 [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table7A_hukou_heterogeneity.doc", word replace ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("Rural hukou") ///
    addtext(Controls, YES, City FE, YES, Year FE, YES)

areg $Y $AI_MAIN $HH_NO_HUKOU $CITY_CONTROLS i.year ///
    if sample_main & resp_urban_hukou==1 [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table7A_hukou_heterogeneity.doc", word append ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("Urban hukou") ///
    addtext(Controls, YES, City FE, YES, Year FE, YES)

generate double ai_urban = $AI_MAIN*resp_urban_hukou
egen long city_hukou_fe = group(city resp_urban_hukou)
local hukou_x ""
foreach x of global HH_NO_HUKOU {
    local hukou_x "`hukou_x' i.resp_urban_hukou#c.`x'"
}
foreach x of global CITY_CONTROLS {
    local hukou_x "`hukou_x' i.resp_urban_hukou#c.`x'"
}

areg $Y $AI_MAIN ai_urban $HH_NO_HUKOU $CITY_CONTROLS `hukou_x' ///
    i.year##i.resp_urban_hukou if sample_main [pweight=$WEIGHT], ///
    absorb(city_hukou_fe) vce(cluster city)
outreg2 using "$OUT/Table7A_hukou_heterogeneity.doc", word append ///
    keep($AI_MAIN ai_urban) se bdec(5) sdec(5) ctitle("Pooled interaction") ///
    addtext(All controls interacted, YES, City-hukou FE, YES, Year-hukou FE, YES)

********************************************************************************
* Table 7B. 城市规模四组：分样本 + 完全交互检验
* 1=超大；2=特大；3=大；4=中小。正式交互以中小城市为基准。
********************************************************************************

use "$MASTER_FILE", clear

local table7b_mode replace
forvalues g=1/4 {
    local gtitle ">=10m"
    if `g'==2 local gtitle "5m to <10m"
    if `g'==3 local gtitle "1m to <5m"
    if `g'==4 local gtitle "<1m"
    areg $Y $AI_MAIN $FULL_CONTROLS i.year ///
        if sample_main & $CITYSIZE==`g' [pweight=$WEIGHT], ///
        absorb(city) vce(cluster city)
    outreg2 using "$OUT/Table7B_city_size_heterogeneity.doc", word `table7b_mode' ///
        keep($AI_MAIN) se bdec(5) sdec(5) ctitle("`gtitle'") ///
        addtext(Controls, YES, City FE, YES, Year FE, YES)
    local table7b_mode append
}

generate double ai_ultra = $AI_MAIN*($CITYSIZE==1)
generate double ai_mega  = $AI_MAIN*($CITYSIZE==2)
generate double ai_large = $AI_MAIN*($CITYSIZE==3)

local size_x ""
foreach x of global FULL_CONTROLS {
    local size_x "`size_x' ib4.$CITYSIZE#c.`x'"
}

areg $Y $AI_MAIN ai_ultra ai_mega ai_large ///
    $FULL_CONTROLS `size_x' i.year##ib4.$CITYSIZE ///
    if sample_main [pweight=$WEIGHT], absorb(city) vce(cluster city)
test ai_ultra ai_mega ai_large
local size_joint_F = r(F)
local size_joint_p = r(p)
outreg2 using "$OUT/Table7B_city_size_heterogeneity.doc", word append ///
    keep($AI_MAIN ai_ultra ai_mega ai_large) se bdec(5) sdec(5) ///
    ctitle("Pooled fully interacted") ///
    addstat(Joint interaction F, `size_joint_F', Joint interaction p, `size_joint_p') ///
    addtext(All controls interacted, YES, City FE, YES, Size-specific year FE, YES)

display as text "四组AI边际效应（交互模型）："
lincom $AI_MAIN + ai_ultra
lincom $AI_MAIN + ai_mega
lincom $AI_MAIN + ai_large
lincom $AI_MAIN

********************************************************************************
* Table 8. 产业结构异质性：分样本 + 连续交互
********************************************************************************

use "$MASTER_FILE", clear
preserve
use "$CITY_FILE", clear
summarize tertiary_secondary if tertiary_secondary<.
local industry_cutoff = r(mean)
restore

generate byte industry_high = (tertiary_secondary>=`industry_cutoff') if tertiary_secondary<.

areg $Y $AI_MAIN $FULL_CONTROLS i.year ///
    if sample_main & industry_high==0 [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table8_industry_heterogeneity.doc", word replace ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("Below mean") ///
    addtext(Controls, YES, City FE, YES, Year FE, YES)

areg $Y $AI_MAIN $FULL_CONTROLS i.year ///
    if sample_main & industry_high==1 [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table8_industry_heterogeneity.doc", word append ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("At/above mean") ///
    addtext(Controls, YES, City FE, YES, Year FE, YES)

generate double ai_structure = $AI_MAIN*tertiary_secondary
areg $Y $AI_MAIN tertiary_secondary ai_structure ///
    $HH_CONTROLS $CITY_NO_IND i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table8_industry_heterogeneity.doc", word append ///
    keep($AI_MAIN tertiary_secondary ai_structure) se bdec(5) sdec(5) ///
    ctitle("Continuous interaction") ///
    addtext(Household controls, YES, Other city controls, YES, City FE, YES, Year FE, YES)

********************************************************************************
* Table 9A. 分期检验：2012-2016 与 2018-2022
* 动因：AI专利密度的分布形态两期差异极大（城市—年份层面偏度由2012年的13.2降到
* 2022年的7.1，取零值的城市占比由37.6%降到3.7%）。i.year只吸收水平不吸收形态，
* 故需检验AI边际效应在两个分布环境下是否稳定。
********************************************************************************

use "$MASTER_FILE", clear

generate byte late = (year>=2018) if year<.
label variable late "1 if 2018-2022 wave, 0 if 2012-2016 wave"
generate double ai_late = $AI_MAIN*late
label variable ai_late "AI x late period"

* (1) 前期 2012-2016
areg $Y $AI_MAIN $FULL_CONTROLS i.year ///
    if sample_main & late==0 [pweight=$WEIGHT], absorb(city) vce(cluster city)
local b_early = _b[$AI_MAIN]
local n_early = e(N)
outreg2 using "$OUT/Table9A_period_split.doc", word replace ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("(1) 2012-2016") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES) ///
    addnote("注：因变量为是否属于中等收入群体。第(1)(2)列为分期子样本估计；", ///
            "第(3)列在合并样本上加入AI×后期交互项，第(4)列进一步允许全部控制变量与时期交互。", ///
            "分期动因是AI专利密度的分布形态两期差异极大：城市—年份层面偏度由2012年的13.2", ///
            "降至2022年的7.1，取零值的城市占比由37.6%降至3.7%，年份固定效应只吸收水平差异、", ///
            "不吸收分布形态差异。")

* (2) 后期 2018-2022
areg $Y $AI_MAIN $FULL_CONTROLS i.year ///
    if sample_main & late==1 [pweight=$WEIGHT], absorb(city) vce(cluster city)
local b_late = _b[$AI_MAIN]
local n_late = e(N)
outreg2 using "$OUT/Table9A_period_split.doc", word append ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("(2) 2018-2022") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (3) 合并样本 + AI×后期交互
areg $Y $AI_MAIN ai_late $FULL_CONTROLS i.year ///
    if sample_main [pweight=$WEIGHT], absorb(city) vce(cluster city)
test ai_late
local p_int = r(p)
display as text "【Table9A】AI×后期 交互项检验 p = " %6.4f `p_int'
display as text "  前期系数=" %9.5f `b_early' "（N=`n_early'）；后期系数=" %9.5f `b_late' "（N=`n_late'）"
lincom $AI_MAIN + ai_late
outreg2 using "$OUT/Table9A_period_split.doc", word append ///
    keep($AI_MAIN ai_late) se bdec(5) sdec(5) ctitle("(3) Interaction") ///
    addstat(Interaction p-value, `p_int') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (4) 合并样本 + 全部控制变量与时期交互（更严格的识别）
local late_x ""
foreach x of global FULL_CONTROLS {
    local late_x "`late_x' i.late#c.`x'"
}
areg $Y $AI_MAIN ai_late $FULL_CONTROLS `late_x' i.year ///
    if sample_main [pweight=$WEIGHT], absorb(city) vce(cluster city)
test ai_late
local p_int_full = r(p)
display as text "【Table9A】全交互设定下 AI×后期 检验 p = " %6.4f `p_int_full'
lincom $AI_MAIN + ai_late
outreg2 using "$OUT/Table9A_period_split.doc", word append ///
    keep($AI_MAIN ai_late) se bdec(5) sdec(5) ctitle("(4) Fully interacted") ///
    addstat(Interaction p-value, `p_int_full') ///
    addtext(All controls interacted, YES, City FE, YES, Year FE, YES)

********************************************************************************
* Table 9B. 分期 × 城市规模：8个子样本
* 1=超大(>=1000万)；2=特大(500-1000万)；3=大(100-500万)；4=中小(<100万)
********************************************************************************

local t9b_mode replace
forvalues p=0/1 {
    local ptitle "2012-2016"
    if `p'==1 local ptitle "2018-2022"
    forvalues g=1/4 {
        local gtitle ">=10m"
        if `g'==2 local gtitle "5m-10m"
        if `g'==3 local gtitle "1m-5m"
        if `g'==4 local gtitle "<1m"
        capture areg $Y $AI_MAIN $FULL_CONTROLS i.year ///
            if sample_main & late==`p' & $CITYSIZE==`g' [pweight=$WEIGHT], ///
            absorb(city) vce(cluster city)
        if _rc {
            display as error "【Table9B】`ptitle' x `gtitle' 估计失败(rc=`=_rc')，跳过该列。"
            continue
        }
        display as text "【Table9B】`ptitle' x `gtitle'：系数=" %9.5f _b[$AI_MAIN] ///
            "  N=" %8.0f e(N) "  组内城市数=" %5.0f e(df_a)+1
        outreg2 using "$OUT/Table9B_period_by_citysize.doc", word `t9b_mode' ///
            keep($AI_MAIN) se bdec(5) sdec(5) ctitle("`ptitle' `gtitle'") ///
            addtext(Controls, YES, City FE, YES, Year FE, YES)
        local t9b_mode append
    }
}

********************************************************************************
* Table 9C. 各城市规模组内部的期间变化：组内 AI + AI×后期 交互
* 直接检验「哪一类城市的AI边际效应随时期发生了变化」，比8列分样本更易读。
********************************************************************************

local t9c_mode replace
forvalues g=1/4 {
    local gtitle ">=10m"
    if `g'==2 local gtitle "5m-10m"
    if `g'==3 local gtitle "1m-5m"
    if `g'==4 local gtitle "<1m"
    capture areg $Y $AI_MAIN ai_late $FULL_CONTROLS i.year ///
        if sample_main & $CITYSIZE==`g' [pweight=$WEIGHT], ///
        absorb(city) vce(cluster city)
    if _rc {
        display as error "【Table9C】`gtitle' 估计失败(rc=`=_rc')，跳过该列。"
        continue
    }
    test ai_late
    local pg = r(p)
    display as text "【Table9C】`gtitle'：AI=" %9.5f _b[$AI_MAIN] ///
        "  AIx后期=" %9.5f _b[ai_late] "  交互p=" %6.4f `pg' "  N=" %8.0f e(N)
    lincom $AI_MAIN + ai_late
    outreg2 using "$OUT/Table9C_citysize_period_interaction.doc", word `t9c_mode' ///
        keep($AI_MAIN ai_late) se bdec(5) sdec(5) ctitle("`gtitle'") ///
        addstat(Interaction p-value, `pg') ///
        addtext(Controls, YES, City FE, YES, Year FE, YES)
    local t9c_mode append
}

********************************************************************************
* Table 10A. 备选主指标：AI企业数的四种函数形式
* 动因：AI企业数取零值的城市—年份仅占0.3%（专利密度为16.8%），取对数后偏度0.44、
* 接近对称（专利密度取对数后仍为2.35），是唯一可通过单调变换基本消除右偏的AI度量。
* 单位统一为千家，便于与专利密度口径的系数量级对照。
********************************************************************************

use "$MASTER_FILE", clear

* 缩尾分位点在唯一城市—年份层面计算
preserve
keep if sample_main
keep city year $AI_FIRM
bysort city year: keep if _n==1
summarize $AI_FIRM, detail
local f_p1  = r(p1)
local f_p99 = r(p99)
restore

generate double firm_raw    = $AI_FIRM/1000                              if $AI_FIRM<.
generate double firm_ln1p   = ln(1+$AI_FIRM)                             if $AI_FIRM<.
generate double firm_asinh  = asinh($AI_FIRM)                            if $AI_FIRM<.
generate double firm_winsor = min(max($AI_FIRM,`f_p1'),`f_p99')/1000     if $AI_FIRM<.
label variable firm_raw    "Cumulative AI firms (000s), raw"
label variable firm_ln1p   "ln(1 + cumulative AI firms)"
label variable firm_asinh  "asinh(cumulative AI firms)"
label variable firm_winsor "Cumulative AI firms (000s), winsorized 1/99"

* (1) 水平值（千家）
areg $Y firm_raw $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
local fb1 = _b[firm_raw]
local fn1 = e(N)
quietly summarize firm_raw if e(sample) [aweight=$WEIGHT]
local fs1 = r(sd)
local fe1 = `fb1'*`fs1'
outreg2 using "$OUT/Table10A_AIfirms_functional_form.doc", word replace ///
    keep(firm_raw) se bdec(5) sdec(5) ctitle("(1) Raw (000s)") ///
    addstat(SD of regressor, `fs1', Effect of 1 SD, `fe1') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES) ///
    addnote("注：因变量为是否属于中等收入群体，核心解释变量改为截至t-1年累计注册的AI企业数。", ///
            "四列样本一致，四种变换均为单调变换、不改变缺失结构，故观测数完全相同。", ///
            "各列量纲不同，横向比较应看「Effect of 1 SD」一行。", ///
            "选用该指标的理由：其取零值的城市—年份仅占0.3%，取对数后偏度0.44、接近对称；", ///
            "而专利密度取零值占16.8%，取对数后偏度仍为2.35，零值堆积无法由单调变换消除。")

* (2) ln(1+x)
areg $Y firm_ln1p $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
local fb2 = _b[firm_ln1p]
quietly summarize firm_ln1p if e(sample) [aweight=$WEIGHT]
local fs2 = r(sd)
local fe2 = `fb2'*`fs2'
outreg2 using "$OUT/Table10A_AIfirms_functional_form.doc", word append ///
    keep(firm_ln1p) se bdec(5) sdec(5) ctitle("(2) ln(1+firms)") ///
    addstat(SD of regressor, `fs2', Effect of 1 SD, `fe2') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (3) asinh
areg $Y firm_asinh $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
local fb3 = _b[firm_asinh]
quietly summarize firm_asinh if e(sample) [aweight=$WEIGHT]
local fs3 = r(sd)
local fe3 = `fb3'*`fs3'
outreg2 using "$OUT/Table10A_AIfirms_functional_form.doc", word append ///
    keep(firm_asinh) se bdec(5) sdec(5) ctitle("(3) asinh(firms)") ///
    addstat(SD of regressor, `fs3', Effect of 1 SD, `fe3') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (4) 缩尾 1/99（千家）
areg $Y firm_winsor $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
local fb4 = _b[firm_winsor]
quietly summarize firm_winsor if e(sample) [aweight=$WEIGHT]
local fs4 = r(sd)
local fe4 = `fb4'*`fs4'
outreg2 using "$OUT/Table10A_AIfirms_functional_form.doc", word append ///
    keep(firm_winsor) se bdec(5) sdec(5) ctitle("(4) Winsor 1/99") ///
    addstat(SD of regressor, `fs4', Effect of 1 SD, `fe4') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

display as text "【Table10A】AI企业数：一个加权标准差对应的中等收入概率变动（N=`fn1'）"
display as text "  (1) 水平(千家) 系数=" %10.5f `fb1' "  SD=" %8.4f `fs1' "  1SD效应=" %9.5f `fe1'
display as text "  (2) ln(1+x)    系数=" %10.5f `fb2' "  SD=" %8.4f `fs2' "  1SD效应=" %9.5f `fe2'
display as text "  (3) asinh      系数=" %10.5f `fb3' "  SD=" %8.4f `fs3' "  1SD效应=" %9.5f `fe3'
display as text "  (4) 缩尾(千家) 系数=" %10.5f `fb4' "  SD=" %8.4f `fs4' "  1SD效应=" %9.5f `fe4'

********************************************************************************
* Table 10B. 稳定性矩阵：两个AI指标 × 四种函数形式 的分期表现
* 每列报告全交互设定（允许全部控制变量与时期交互）下的当期系数与AI×后期交互项，
* 并在附加统计量中给出前期、后期分样本系数与交互项p值，用于判断哪一组合最稳定。
********************************************************************************

* 补充构造专利密度的四种变换（口径与Table 5C一致）
preserve
keep if sample_main
keep city year $AI_MAIN
bysort city year: keep if _n==1
summarize $AI_MAIN, detail
local ai_p1  = r(p1)
local ai_p99 = r(p99)
restore

generate double ai_raw    = $AI_MAIN                            if $AI_MAIN<.
generate double ai_ln1p   = ln(1+$AI_MAIN)                       if $AI_MAIN<.
generate double ai_asinh  = asinh($AI_MAIN)                      if $AI_MAIN<.
generate double ai_winsor = min(max($AI_MAIN,`ai_p1'),`ai_p99')  if $AI_MAIN<.
generate byte late = (year>=2018) if year<.
label variable late "1 if 2018-2022 wave"

local t10b_mode replace
foreach x in ai_raw ai_ln1p ai_asinh ai_winsor firm_raw firm_ln1p firm_asinh firm_winsor {
    capture drop x_late
    generate double x_late = `x'*late
    label variable x_late "AI measure x late period"

    quietly areg $Y `x' $FULL_CONTROLS i.year ///
        if sample_main & late==0 [pweight=$WEIGHT], absorb(city) vce(cluster city)
    local be = _b[`x']
    quietly areg $Y `x' $FULL_CONTROLS i.year ///
        if sample_main & late==1 [pweight=$WEIGHT], absorb(city) vce(cluster city)
    local bl = _b[`x']

    local lx ""
    foreach c of global FULL_CONTROLS {
        local lx "`lx' i.late#c.`c'"
    }
    areg $Y `x' x_late $FULL_CONTROLS `lx' i.year ///
        if sample_main [pweight=$WEIGHT], absorb(city) vce(cluster city)
    test x_late
    local pp = r(p)
    display as text "【Table10B】" %-12s "`x'" "  前期=" %10.5f `be' ///
        "  后期=" %10.5f `bl' "  全交互p=" %6.4f `pp'
    outreg2 using "$OUT/Table10B_stability_matrix.doc", word `t10b_mode' ///
        keep(`x' x_late) se bdec(5) sdec(5) ctitle("`x'") ///
        addstat(Early coef, `be', Late coef, `bl', Interaction p-value, `pp') ///
        addtext(All controls interacted, YES, City FE, YES, Year FE, YES)
    local t10b_mode append
}

