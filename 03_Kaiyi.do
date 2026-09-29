clear all
set more off
set linesize 255

*============================= 暂命名数据文件，需修改文件名 =======================*
global ROOT     ""                 
global MAP_FILE ""      
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

merge m:1 countyid using "$MAP_FILE", keepusing(code) generate(_merge_geo)
tabulate _merge_geo
keep if _merge_geo == 3
drop _merge_geo

* 六位区县码转换
generate long city = floor(code/100)*100
replace city = floor(code/10000)*10000 if inlist(floor(code/10000),11,12,31,50)
drop code

merge m:1 year city using "$CITY_FILE", generate(_merge_city)
tabulate _merge_city
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
* Table 1. 加权描述性统计 (Descriptive Statistics)
********************************************************************************

use "$MASTER_FILE", clear
global DESC_VARS "$Y $AI_MAIN $AI_FIRM resp_age resp_age2 resp_male resp_ever_married resp_urban_hukou resp_educ_years resp_health_good5 hhsize_official child_ratio older_ratio ln_gdp_pc tertiary_secondary gov_exp_gdp univ_per10k"

tabstat $DESC_VARS if sample_main [aweight=$WEIGHT], ///
    statistics(n mean sd min p50 max) columns(statistics) save
matrix Table1 = r(StatTotal)'
putexcel set "$OUT/Table1_weighted_descriptives.xlsx", replace
putexcel A1=matrix(Table1), names


********************************************************************************
* Table 2. 基准回归 (Baseline Estimates)
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
* Table 3. 收入组转移 (Income Group Transitions)
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
* Table 4. 工具变量 (Instrumental Variable Estimates)
********************************************************************************

use "$MASTER_FILE", clear
generate byte sample_iv = (sample_main==1 & $IV_MAIN<.)

* (1) First stage
areg $AI_MAIN $IV_MAIN $FULL_CONTROLS i.year if sample_iv ///
    [pweight=$WEIGHT], absorb(city) vce(cluster city)
test $IV_MAIN
local firstF = r(F)
outreg2 using "$OUT/Table4_IV_main.doc", word replace ///
    keep($IV_MAIN) se bdec(5) sdec(5) ctitle("(1) First stage") ///
    addstat(Excluded-IV F, `firstF') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (2) Same-sample OLS
areg $Y $AI_MAIN $FULL_CONTROLS i.year if sample_iv ///
    [pweight=$WEIGHT], absorb(city) vce(cluster city)
outreg2 using "$OUT/Table4_IV_main.doc", word append ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("(2) Same-sample OLS") ///
    addstat(Excluded-IV F, `firstF') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (3) Reduced form
areg $Y $IV_MAIN $FULL_CONTROLS i.year if sample_iv ///
    [pweight=$WEIGHT], absorb(city) vce(cluster city)
outreg2 using "$OUT/Table4_IV_main.doc", word append ///
    keep($IV_MAIN) se bdec(5) sdec(5) ctitle("(3) Reduced form") ///
    addstat(Excluded-IV F, `firstF') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (4) 2SLS
ivregress 2sls $Y $FULL_CONTROLS i.year i.city ///
    ($AI_MAIN=$IV_MAIN) if sample_iv [pweight=$WEIGHT], ///
    vce(cluster city) small
outreg2 using "$OUT/Table4_IV_main.doc", word append ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("(4) 2SLS") ///
    addstat(Excluded-IV F, `firstF') ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)


********************************************************************************
* Table 5. 替代AI指标 (Robustness to Alternative AI Measures)
* 六列：三种AI专利变换 + 三种AI企业数变换
********************************************************************************

use "$MASTER_FILE", clear

* 构造AI专利密度的三种变换
generate double ai_raw    = $AI_MAIN                            if $AI_MAIN<.
generate double ai_asinh  = asinh($AI_MAIN)                     if $AI_MAIN<.
generate double ai_ln1p   = ln(1+$AI_MAIN)                      if $AI_MAIN<.
label variable ai_raw    "AI patent density, raw"
label variable ai_asinh  "asinh(AI patent density)"
label variable ai_ln1p   "ln(1 + AI patent density)"

* 构造AI企业数的三种变换
generate double firm_raw    = $AI_FIRM                            if $AI_FIRM<.
generate double firm_ln1p   = ln(1+$AI_FIRM)                      if $AI_FIRM<.
generate double firm_asinh  = asinh($AI_FIRM)                     if $AI_FIRM<.
label variable firm_raw    "Cumulative AI firms (000s), raw"
label variable firm_ln1p   "ln(1 + cumulative AI firms)"
label variable firm_asinh  "asinh(cumulative AI firms)"

* (1) AI专利 - 水平值
areg $Y ai_raw $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table5_alternative_AI_measures.doc", word replace ///
    keep(ai_raw) se bdec(5) sdec(5) ctitle("ai_raw") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (2) AI专利 - ln(1+x)
areg $Y ai_ln1p $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table5_alternative_AI_measures.doc", word append ///
    keep(ai_ln1p) se bdec(5) sdec(5) ctitle("ai_ln1p") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (3) AI专利 - asinh
areg $Y ai_asinh $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table5_alternative_AI_measures.doc", word append ///
    keep(ai_asinh) se bdec(5) sdec(5) ctitle("ai_asinh") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (4) AI企业 - 水平值
areg $Y firm_raw $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table5_alternative_AI_measures.doc", word append ///
    keep(firm_raw) se bdec(5) sdec(5) ctitle("firm_raw") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (5) AI企业 - ln(1+x)
areg $Y firm_ln1p $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table5_alternative_AI_measures.doc", word append ///
    keep(firm_ln1p) se bdec(5) sdec(5) ctitle("firm_ln1p") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (6) AI企业 - asinh
areg $Y firm_asinh $FULL_CONTROLS i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table5_alternative_AI_measures.doc", word append ///
    keep(firm_asinh) se bdec(5) sdec(5) ctitle("firm_asinh") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)


********************************************************************************
* Table 6. 替代样本与规格 (Robustness to Alternative Samples and Specifications)
* (1) 排除超大城市 (2) 年龄<=65 (3) 排除高收入 (4) 省份×年份FE
********************************************************************************

use "$MASTER_FILE", clear
generate byte sample_iv = (sample_main==1 & $IV_MAIN<.)

* (1) Excluding cities >= 10m (city_size4 != 1)
areg $Y $AI_MAIN $FULL_CONTROLS i.year ///
    if sample_main & $CITYSIZE!=1 [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table6_robustness_samples.doc", word replace ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("(1) Excluding cities >= 10m") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (2) Age <= 65
areg $Y $AI_MAIN $FULL_CONTROLS i.year ///
    if sample_main & resp_age<=65 [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table6_robustness_samples.doc", word append ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("(2) Age <= 65") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (3) Excluding high-income
areg $Y $AI_MAIN $FULL_CONTROLS i.year ///
    if sample_main & income_group3_real2018!=3 [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table6_robustness_samples.doc", word append ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("(3) Excluding high-income") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)

* (4) Province x year FE
areg $Y $AI_MAIN $FULL_CONTROLS i.prov_code#i.year ///
    if sample_main & sample_iv [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table6_robustness_samples.doc", word append ///
    keep($AI_MAIN) se bdec(5) sdec(5) ctitle("(4) Province x year FE") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Province x year FE, YES)


********************************************************************************
* Table 7. 收入来源响应 (Income Source Responses)
* 三类收入 × 两个边际：receipt + IHS full-sample
********************************************************************************

use "$MASTER_FILE", clear

foreach s in wage business property {
    generate byte receive_`s' = (income_`s'_real2018>0) if income_`s'_real2018<.
    generate double ihs_`s' = asinh(income_`s'_real2018) if income_`s'_real2018<.
}

* 六列：wage_receipt, ihs_wage, business_receipt, ihs_business, property_receipt, ihs_property
local table7_mode replace
foreach y in receive_wage ihs_wage receive_business ihs_business receive_property ihs_property {
    areg `y' $AI_MAIN $FULL_CONTROLS i.year ///
        if sample_covars & $AI_MAIN<. & `y'<. [pweight=$WEIGHT], ///
        absorb(city) vce(cluster city)
    outreg2 using "$OUT/Table7_income_sources.doc", word `table7_mode' ///
        keep($AI_MAIN) se bdec(5) sdec(5) ctitle("`y'") ///
        addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)
    local table7_mode append
}


********************************************************************************
* Table 8. 异质性分析 (Heterogeneity: Hukou, City Size, Industrial Structure)
* 三列：户口交互、城市规模交互、产业结构连续交互
********************************************************************************

use "$MASTER_FILE", clear

* ---------- (1) Hukou status: fully interacted ----------
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
outreg2 using "$OUT/Table8_heterogeneity.doc", word replace ///
    keep($AI_MAIN ai_urban) se bdec(5) sdec(5) ctitle("(1) Hukou status") ///
    addtext(Household controls, YES, City controls, YES, All controls interacted, YES, City-hukou FE, YES, Year FE, YES)

* ---------- (2) City size: fully interacted (reference = <1m) ----------
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
outreg2 using "$OUT/Table8_heterogeneity.doc", word append ///
    keep($AI_MAIN ai_ultra ai_mega ai_large) se bdec(5) sdec(5) ///
    ctitle("(2) City size") ///
    addstat(Joint city-size interaction F, `size_joint_F', Joint city-size interaction p, `size_joint_p') ///
    addtext(Household controls, YES, City controls, YES, All controls interacted, YES, City FE, YES, Year FE, YES)

* ---------- (3) Industrial structure: continuous interaction ----------
generate double ai_structure = $AI_MAIN*tertiary_secondary

areg $Y $AI_MAIN tertiary_secondary ai_structure ///
    $HH_CONTROLS $CITY_NO_IND i.year if sample_main [pweight=$WEIGHT], ///
    absorb(city) vce(cluster city)
outreg2 using "$OUT/Table8_heterogeneity.doc", word append ///
    keep($AI_MAIN tertiary_secondary ai_structure) se bdec(5) sdec(5) ///
    ctitle("(3) Industrial structure") ///
    addtext(Household controls, YES, City controls, YES, City FE, YES, Year FE, YES)


********************************************************************************
* 完成
********************************************************************************

log close
display as text _newline(2) "============================================================"
display as text "  All tables (Table 1-8) have been generated."
display as text "  Output directory: $OUT"
display as text "============================================================"