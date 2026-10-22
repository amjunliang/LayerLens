
//
//  LayerLens_AttrIdentifiers.m
//  Lookin
//
//  Created by Li Kai on 2019/9/18.
//  https://lookin.work
//



#import "LayerLens_AttrIdentifiers.h"

// value 不能重复（AppDelegate 里的 runTests 有相关 test）
// 如果要去掉某一项可以考虑注释掉而非直接删除，以防止新项和旧项的 value 相同而引发 preference 错乱（这些 value 会被存储到 userDefaults 里）

#pragma mark - Group

LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_None = @"n";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_Class = @"c";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_Relation = @"r";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_Layout = @"l";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_AutoLayout = @"a";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_ViewLayer = @"vl";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_UIImageView = @"i";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_UILabel = @"la";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_UIControl = @"co";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_UIButton = @"b";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_UIScrollView = @"s";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_UITableView = @"ta";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_UITextView = @"te";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_UITextField = @"tf";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_UIVisualEffectView = @"ve";
LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_UIStackView = @"UIStackView";

LayerLens_AttrGroupIdentifier const LayerLens_AttrGroup_UserCustom = @"guc"; // user custom

#pragma mark - Section

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_None = @"n";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UserCustom = @"sec_ctm";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_Class_Class = @"cl_c";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_Relation_Relation = @"r_r";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_Layout_Frame = @"l_f";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_Layout_Bounds = @"l_b";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_Layout_SafeArea = @"l_s";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_Layout_Position = @"l_p";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_Layout_AnchorPoint = @"l_a";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_AutoLayout_Hugging = @"a_h";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_AutoLayout_Resistance = @"a_r";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_AutoLayout_Constraints = @"a_c";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_AutoLayout_IntrinsicSize = @"a_i";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_ViewLayer_Visibility = @"v_v";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_ViewLayer_InterationAndMasks = @"v_i";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_ViewLayer_Corner = @"v_c";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_ViewLayer_BgColor = @"v_b";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_ViewLayer_Border = @"v_bo";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_ViewLayer_Shadow = @"v_s";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_ViewLayer_ContentMode = @"v_co";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_ViewLayer_TintColor = @"v_t";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_ViewLayer_Tag = @"v_ta";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIImageView_Name = @"i_n";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIImageView_Open = @"i_o";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UILabel_Text = @"lb_t";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UILabel_Font = @"lb_f";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UILabel_NumberOfLines = @"lb_n";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UILabel_TextColor = @"lb_tc";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UILabel_BreakMode = @"lb_b";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UILabel_Alignment = @"lb_a";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UILabel_CanAdjustFont = @"lb_c";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIControl_EnabledSelected = @"c_e";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIControl_VerAlignment = @"c_v";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIControl_HorAlignment = @"c_h";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIControl_QMUIOutsideEdge = @"c_o";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIButton_ContentInsets = @"b_c";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIButton_TitleInsets = @"b_t";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIButton_ImageInsets = @"b_i";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIScrollView_ContentInset = @"s_c";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIScrollView_AdjustedInset = @"s_a";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIScrollView_IndicatorInset = @"s_i";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIScrollView_Offset = @"s_o";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIScrollView_ContentSize = @"s_cs";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIScrollView_Behavior = @"s_b";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIScrollView_ShowsIndicator = @"s_si";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIScrollView_Bounce = @"s_bo";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIScrollView_ScrollPaging = @"s_s";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIScrollView_ContentTouches = @"s_ct";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIScrollView_Zoom = @"s_z";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIScrollView_QMUIInitialInset = @"s_ii";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITableView_Style = @"t_s";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITableView_SectionsNumber = @"t_sn";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITableView_RowsNumber = @"t_r";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITableView_SeparatorStyle = @"t_ss";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITableView_SeparatorColor = @"t_sc";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITableView_SeparatorInset = @"t_si";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITextView_Basic = @"tv_b";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITextView_Text = @"tv_t";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITextView_Font = @"tv_f";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITextView_TextColor = @"tv_tc";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITextView_Alignment = @"tv_a";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITextView_ContainerInset = @"tv_c";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITextField_Text = @"tf_t";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITextField_Placeholder = @"tf_p";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITextField_Font = @"tf_f";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITextField_TextColor = @"tf_tc";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITextField_Alignment = @"tf_a";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITextField_Clears = @"tf_c";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITextField_CanAdjustFont = @"tf_ca";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UITextField_ClearButtonMode = @"tf_cb";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIVisualEffectView_Style = @"ve_s";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIVisualEffectView_QMUIForegroundColor = @"ve_f";

LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIStackView_Axis = @"usv_axis";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIStackView_Distribution = @"usv_dis";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIStackView_Alignment = @"usv_align";
LayerLens_AttrSectionIdentifier const LayerLens_AttrSec_UIStackView_Spacing = @"usv_spa";

#pragma mark - Attr

LayerLens_AttrIdentifier const LayerLens_Attr_None = @"n";
LayerLens_AttrIdentifier const LayerLens_Attr_UserCustom = @"ctm";

LayerLens_AttrIdentifier const LayerLens_Attr_Class_Class_Class = @"c_c_c";


LayerLens_AttrIdentifier const LayerLens_Attr_Relation_Relation_Relation = @"r_r_r";

LayerLens_AttrIdentifier const LayerLens_Attr_Layout_Frame_Frame = @"l_f_f";
LayerLens_AttrIdentifier const LayerLens_Attr_Layout_Bounds_Bounds = @"l_b_b";
LayerLens_AttrIdentifier const LayerLens_Attr_Layout_SafeArea_SafeArea = @"l_s_s";
LayerLens_AttrIdentifier const LayerLens_Attr_Layout_Position_Position = @"l_p_p";
LayerLens_AttrIdentifier const LayerLens_Attr_Layout_AnchorPoint_AnchorPoint = @"l_a_a";

LayerLens_AttrIdentifier const LayerLens_Attr_AutoLayout_Hugging_Hor = @"al_h_h";
LayerLens_AttrIdentifier const LayerLens_Attr_AutoLayout_Hugging_Ver = @"al_h_v";
LayerLens_AttrIdentifier const LayerLens_Attr_AutoLayout_Resistance_Hor = @"al_r_h";
LayerLens_AttrIdentifier const LayerLens_Attr_AutoLayout_Resistance_Ver = @"al_r_v";
LayerLens_AttrIdentifier const LayerLens_Attr_AutoLayout_Constraints_Constraints = @"al_c_c";
LayerLens_AttrIdentifier const LayerLens_Attr_AutoLayout_IntrinsicSize_Size = @"cl_i_s";

LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_Visibility_Hidden = @"vl_v_h";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_Visibility_Opacity = @"vl_v_o";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_InterationAndMasks_Interaction = @"vl_i_i";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_InterationAndMasks_MasksToBounds = @"vl_i_m";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_Corner_Radius = @"vl_c_r";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_BgColor_BgColor = @"vl_b_b";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_Border_Color = @"vl_b_c";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_Border_Width = @"vl_b_w";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_Shadow_Color = @"vl_s_c";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_Shadow_Opacity = @"vl_s_o";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_Shadow_Radius = @"vl_s_r";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_Shadow_OffsetW = @"vl_s_ow";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_Shadow_OffsetH = @"vl_s_oh";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_ContentMode_Mode = @"vl_c_m";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_TintColor_Color = @"vl_t_c";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_TintColor_Mode = @"vl_t_m";
LayerLens_AttrIdentifier const LayerLens_Attr_ViewLayer_Tag_Tag = @"vl_t_t";

LayerLens_AttrIdentifier const LayerLens_Attr_UIImageView_Name_Name = @"iv_n_n";
LayerLens_AttrIdentifier const LayerLens_Attr_UIImageView_Open_Open = @"iv_o_o";

LayerLens_AttrIdentifier const LayerLens_Attr_UILabel_Text_Text = @"lb_t_t";
LayerLens_AttrIdentifier const LayerLens_Attr_UILabel_Font_Name = @"lb_f_n";
LayerLens_AttrIdentifier const LayerLens_Attr_UILabel_Font_Size = @"lb_f_s";
LayerLens_AttrIdentifier const LayerLens_Attr_UILabel_NumberOfLines_NumberOfLines = @"lb_n_n";
LayerLens_AttrIdentifier const LayerLens_Attr_UILabel_TextColor_Color = @"lb_t_c";
LayerLens_AttrIdentifier const LayerLens_Attr_UILabel_Alignment_Alignment = @"lb_a_a";
LayerLens_AttrIdentifier const LayerLens_Attr_UILabel_BreakMode_Mode = @"lb_b_m";
LayerLens_AttrIdentifier const LayerLens_Attr_UILabel_CanAdjustFont_CanAdjustFont = @"lb_c_c";

LayerLens_AttrIdentifier const LayerLens_Attr_UIControl_EnabledSelected_Enabled = @"ct_e_e";
LayerLens_AttrIdentifier const LayerLens_Attr_UIControl_EnabledSelected_Selected = @"ct_e_s";
LayerLens_AttrIdentifier const LayerLens_Attr_UIControl_VerAlignment_Alignment = @"ct_v_a";
LayerLens_AttrIdentifier const LayerLens_Attr_UIControl_HorAlignment_Alignment = @"ct_h_a";
LayerLens_AttrIdentifier const LayerLens_Attr_UIControl_QMUIOutsideEdge_Edge = @"ct_o_e";

LayerLens_AttrIdentifier const LayerLens_Attr_UIButton_ContentInsets_Insets = @"bt_c_i";
LayerLens_AttrIdentifier const LayerLens_Attr_UIButton_TitleInsets_Insets = @"bt_t_i";
LayerLens_AttrIdentifier const LayerLens_Attr_UIButton_ImageInsets_Insets = @"bt_i_i";

LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_Offset_Offset = @"sv_o_o";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_ContentSize_Size = @"sv_c_s";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_ContentInset_Inset = @"sv_c_i";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_AdjustedInset_Inset = @"sv_a_i";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_Behavior_Behavior = @"sv_b_b";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_IndicatorInset_Inset = @"sv_i_i";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_ScrollPaging_ScrollEnabled = @"sv_s_s";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_ScrollPaging_PagingEnabled = @"sv_s_p";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_Bounce_Ver = @"sv_b_v";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_Bounce_Hor = @"sv_b_h";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_ShowsIndicator_Hor = @"sv_h_h";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_ShowsIndicator_Ver = @"sv_s_v";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_ContentTouches_Delay = @"sv_c_d";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_ContentTouches_CanCancel = @"sv_c_c";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_Zoom_MinScale = @"sv_z_mi";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_Zoom_MaxScale = @"sv_z_ma";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_Zoom_Scale = @"sv_z_s";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_Zoom_Bounce = @"sv_z_b";
LayerLens_AttrIdentifier const LayerLens_Attr_UIScrollView_QMUIInitialInset_Inset = @"sv_qi_i";

LayerLens_AttrIdentifier const LayerLens_Attr_UITableView_Style_Style = @"tv_s_s";
LayerLens_AttrIdentifier const LayerLens_Attr_UITableView_SectionsNumber_Number = @"tv_s_n";
LayerLens_AttrIdentifier const LayerLens_Attr_UITableView_RowsNumber_Number = @"tv_r_n";
LayerLens_AttrIdentifier const LayerLens_Attr_UITableView_SeparatorInset_Inset = @"tv_s_i";
LayerLens_AttrIdentifier const LayerLens_Attr_UITableView_SeparatorColor_Color = @"tv_s_c";
LayerLens_AttrIdentifier const LayerLens_Attr_UITableView_SeparatorStyle_Style = @"tv_ss_s";

LayerLens_AttrIdentifier const LayerLens_Attr_UITextView_Font_Name = @"te_f_n";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextView_Font_Size = @"te_f_s";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextView_Basic_Editable = @"te_b_e";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextView_Basic_Selectable = @"te_b_s";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextView_Text_Text = @"te_t_t";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextView_TextColor_Color = @"te_t_c";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextView_Alignment_Alignment = @"te_a_a";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextView_ContainerInset_Inset = @"te_c_i";

LayerLens_AttrIdentifier const LayerLens_Attr_UITextField_Text_Text = @"tf_t_t";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextField_Placeholder_Placeholder = @"tf_p_p";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextField_Font_Name = @"tf_f_n";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextField_Font_Size = @"tf_f_s";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextField_TextColor_Color = @"tf_t_c";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextField_Alignment_Alignment = @"tf_a_a";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextField_Clears_ClearsOnBeginEditing = @"tf_c_c";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextField_Clears_ClearsOnInsertion = @"tf_c_co";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextField_CanAdjustFont_CanAdjustFont = @"tf_c_ca";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextField_CanAdjustFont_MinSize = @"tf_c_m";
LayerLens_AttrIdentifier const LayerLens_Attr_UITextField_ClearButtonMode_Mode = @"tf_cb_m";

LayerLens_AttrIdentifier const LayerLens_Attr_UIVisualEffectView_Style_Style = @"ve_s_s";
LayerLens_AttrIdentifier const LayerLens_Attr_UIVisualEffectView_QMUIForegroundColor_Color = @"ve_f_c";

LayerLens_AttrIdentifier const LayerLens_Attr_UIStackView_Axis_Axis = @"usv_axis_axis";
LayerLens_AttrIdentifier const LayerLens_Attr_UIStackView_Distribution_Distribution = @"usv_dis_dis";
LayerLens_AttrIdentifier const LayerLens_Attr_UIStackView_Alignment_Alignment = @"usv_ali_ali";
LayerLens_AttrIdentifier const LayerLens_Attr_UIStackView_Spacing_Spacing = @"usv_spa_spa";

