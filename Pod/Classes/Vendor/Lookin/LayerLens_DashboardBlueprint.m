
//
//  LayerLens_DashboardBlueprint.m
//  Lookin
//
//  Created by Li Kai on 2019/6/5.
//  https://lookin.work
//



#import "LayerLens_DashboardBlueprint.h"

@implementation LayerLens_DashboardBlueprint

+ (NSArray<LayerLens_AttrGroupIdentifier> *)groupIDs {
    static NSArray<LayerLens_AttrGroupIdentifier> *array;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{
        array = @[
            LayerLens_AttrGroup_Class,
            LayerLens_AttrGroup_Relation,
            LayerLens_AttrGroup_Layout,
            LayerLens_AttrGroup_AutoLayout,
            LayerLens_AttrGroup_ViewLayer,
            LayerLens_AttrGroup_UIStackView,
            LayerLens_AttrGroup_UIVisualEffectView,
            LayerLens_AttrGroup_UIImageView,
            LayerLens_AttrGroup_UILabel,
            LayerLens_AttrGroup_UIControl,
            LayerLens_AttrGroup_UIButton,
            LayerLens_AttrGroup_UIScrollView,
            LayerLens_AttrGroup_UITableView,
            LayerLens_AttrGroup_UITextView,
            LayerLens_AttrGroup_UITextField
        ];
    });
    return array;
}

+ (NSArray<LayerLens_AttrSectionIdentifier> *)sectionIDsForGroupID:(LayerLens_AttrGroupIdentifier)groupID {
    static NSDictionary<LayerLens_AttrGroupIdentifier, NSArray<LayerLens_AttrSectionIdentifier> *> *dict;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{
        dict = @{
            LayerLens_AttrGroup_Class: @[LayerLens_AttrSec_Class_Class],
            
            LayerLens_AttrGroup_Relation: @[LayerLens_AttrSec_Relation_Relation],
            
            LayerLens_AttrGroup_Layout: @[LayerLens_AttrSec_Layout_Frame,
                                      LayerLens_AttrSec_Layout_Bounds,
                                      LayerLens_AttrSec_Layout_SafeArea,
                                      LayerLens_AttrSec_Layout_Position,
                                      LayerLens_AttrSec_Layout_AnchorPoint],
            
            LayerLens_AttrGroup_AutoLayout: @[LayerLens_AttrSec_AutoLayout_Constraints,
                                          LayerLens_AttrSec_AutoLayout_IntrinsicSize,
                                          LayerLens_AttrSec_AutoLayout_Hugging,
                                          LayerLens_AttrSec_AutoLayout_Resistance],
            
            LayerLens_AttrGroup_ViewLayer: @[
                LayerLens_AttrSec_ViewLayer_Visibility,
                LayerLens_AttrSec_ViewLayer_InterationAndMasks,
                LayerLens_AttrSec_ViewLayer_BgColor,
                LayerLens_AttrSec_ViewLayer_Border,
                LayerLens_AttrSec_ViewLayer_Corner,
                LayerLens_AttrSec_ViewLayer_Shadow,
                LayerLens_AttrSec_ViewLayer_ContentMode,
                LayerLens_AttrSec_ViewLayer_TintColor,
                LayerLens_AttrSec_ViewLayer_Tag
            ],
            
            LayerLens_AttrGroup_UIStackView: @[
                LayerLens_AttrSec_UIStackView_Axis,
                LayerLens_AttrSec_UIStackView_Distribution,
                LayerLens_AttrSec_UIStackView_Alignment,
                LayerLens_AttrSec_UIStackView_Spacing
            ],
            
            LayerLens_AttrGroup_UIVisualEffectView: @[
                LayerLens_AttrSec_UIVisualEffectView_Style,
                LayerLens_AttrSec_UIVisualEffectView_QMUIForegroundColor
            ],
            
            LayerLens_AttrGroup_UIImageView: @[LayerLens_AttrSec_UIImageView_Name,
                                           LayerLens_AttrSec_UIImageView_Open],
            
            LayerLens_AttrGroup_UILabel: @[
                LayerLens_AttrSec_UILabel_Text,
                LayerLens_AttrSec_UILabel_Font,
                LayerLens_AttrSec_UILabel_NumberOfLines,
                LayerLens_AttrSec_UILabel_TextColor,
                LayerLens_AttrSec_UILabel_BreakMode,
                LayerLens_AttrSec_UILabel_Alignment,
                LayerLens_AttrSec_UILabel_CanAdjustFont],
            
            LayerLens_AttrGroup_UIControl: @[LayerLens_AttrSec_UIControl_EnabledSelected,
                                         LayerLens_AttrSec_UIControl_QMUIOutsideEdge,
                                         LayerLens_AttrSec_UIControl_VerAlignment,
                                         LayerLens_AttrSec_UIControl_HorAlignment],
            
            LayerLens_AttrGroup_UIButton: @[LayerLens_AttrSec_UIButton_ContentInsets,
                                        LayerLens_AttrSec_UIButton_TitleInsets,
                                        LayerLens_AttrSec_UIButton_ImageInsets],
            
            LayerLens_AttrGroup_UIScrollView: @[LayerLens_AttrSec_UIScrollView_ContentInset,
                                            LayerLens_AttrSec_UIScrollView_AdjustedInset,
                                            LayerLens_AttrSec_UIScrollView_QMUIInitialInset,
                                            LayerLens_AttrSec_UIScrollView_IndicatorInset,
                                            LayerLens_AttrSec_UIScrollView_Offset,
                                            LayerLens_AttrSec_UIScrollView_ContentSize,
                                            LayerLens_AttrSec_UIScrollView_Behavior,
                                            LayerLens_AttrSec_UIScrollView_ShowsIndicator,
                                            LayerLens_AttrSec_UIScrollView_Bounce,
                                            LayerLens_AttrSec_UIScrollView_ScrollPaging,
                                            LayerLens_AttrSec_UIScrollView_ContentTouches,
                                            LayerLens_AttrSec_UIScrollView_Zoom],
            
            LayerLens_AttrGroup_UITableView: @[LayerLens_AttrSec_UITableView_Style,
                                           LayerLens_AttrSec_UITableView_SectionsNumber,
                                           LayerLens_AttrSec_UITableView_RowsNumber,
                                           LayerLens_AttrSec_UITableView_SeparatorStyle,
                                           LayerLens_AttrSec_UITableView_SeparatorColor,
                                           LayerLens_AttrSec_UITableView_SeparatorInset],
            
            LayerLens_AttrGroup_UITextView: @[LayerLens_AttrSec_UITextView_Basic,
                                          LayerLens_AttrSec_UITextView_Text,
                                          LayerLens_AttrSec_UITextView_Font,
                                          LayerLens_AttrSec_UITextView_TextColor,
                                          LayerLens_AttrSec_UITextView_Alignment,
                                          LayerLens_AttrSec_UITextView_ContainerInset],
            
            LayerLens_AttrGroup_UITextField: @[LayerLens_AttrSec_UITextField_Text,
                                           LayerLens_AttrSec_UITextField_Placeholder,
                                           LayerLens_AttrSec_UITextField_Font,
                                           LayerLens_AttrSec_UITextField_TextColor,
                                           LayerLens_AttrSec_UITextField_Alignment,
                                           LayerLens_AttrSec_UITextField_Clears,
                                           LayerLens_AttrSec_UITextField_CanAdjustFont,
                                           LayerLens_AttrSec_UITextField_ClearButtonMode],
            
        };
    });
    return dict[groupID];
}

+ (NSArray<LayerLens_AttrIdentifier> *)attrIDsForSectionID:(LayerLens_AttrSectionIdentifier)sectionID {
    static NSDictionary<LayerLens_AttrSectionIdentifier, NSArray<LayerLens_AttrIdentifier> *> *dict;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{
        dict = @{
            LayerLens_AttrSec_Class_Class: @[LayerLens_Attr_Class_Class_Class],
            
            LayerLens_AttrSec_Relation_Relation: @[LayerLens_Attr_Relation_Relation_Relation],
            
            LayerLens_AttrSec_Layout_Frame: @[LayerLens_Attr_Layout_Frame_Frame],
            LayerLens_AttrSec_Layout_Bounds: @[LayerLens_Attr_Layout_Bounds_Bounds],
            LayerLens_AttrSec_Layout_SafeArea: @[LayerLens_Attr_Layout_SafeArea_SafeArea],
            LayerLens_AttrSec_Layout_Position: @[LayerLens_Attr_Layout_Position_Position],
            LayerLens_AttrSec_Layout_AnchorPoint: @[LayerLens_Attr_Layout_AnchorPoint_AnchorPoint],
            
            LayerLens_AttrSec_AutoLayout_Hugging: @[LayerLens_Attr_AutoLayout_Hugging_Hor,
                                                LayerLens_Attr_AutoLayout_Hugging_Ver],
            LayerLens_AttrSec_AutoLayout_Resistance: @[LayerLens_Attr_AutoLayout_Resistance_Hor,
                                                   LayerLens_Attr_AutoLayout_Resistance_Ver],
            LayerLens_AttrSec_AutoLayout_Constraints: @[LayerLens_Attr_AutoLayout_Constraints_Constraints],
            LayerLens_AttrSec_AutoLayout_IntrinsicSize: @[LayerLens_Attr_AutoLayout_IntrinsicSize_Size],
            
            LayerLens_AttrSec_ViewLayer_Visibility: @[LayerLens_Attr_ViewLayer_Visibility_Hidden,
                                                  LayerLens_Attr_ViewLayer_Visibility_Opacity],
            
            LayerLens_AttrSec_ViewLayer_InterationAndMasks: @[LayerLens_Attr_ViewLayer_InterationAndMasks_Interaction,
                                                          LayerLens_Attr_ViewLayer_InterationAndMasks_MasksToBounds],
            
            LayerLens_AttrSec_ViewLayer_Corner: @[LayerLens_Attr_ViewLayer_Corner_Radius],
            
            LayerLens_AttrSec_ViewLayer_BgColor: @[LayerLens_Attr_ViewLayer_BgColor_BgColor],
            
            LayerLens_AttrSec_ViewLayer_Border: @[LayerLens_Attr_ViewLayer_Border_Color,
                                              LayerLens_Attr_ViewLayer_Border_Width],
            
            LayerLens_AttrSec_ViewLayer_Shadow: @[LayerLens_Attr_ViewLayer_Shadow_Color,
                                              LayerLens_Attr_ViewLayer_Shadow_Opacity,
                                              LayerLens_Attr_ViewLayer_Shadow_Radius,
                                              LayerLens_Attr_ViewLayer_Shadow_OffsetW,
                                              LayerLens_Attr_ViewLayer_Shadow_OffsetH],
            
            LayerLens_AttrSec_ViewLayer_ContentMode: @[LayerLens_Attr_ViewLayer_ContentMode_Mode],
            
            LayerLens_AttrSec_ViewLayer_TintColor: @[LayerLens_Attr_ViewLayer_TintColor_Color,
                                                 LayerLens_Attr_ViewLayer_TintColor_Mode],
            
            LayerLens_AttrSec_ViewLayer_Tag: @[LayerLens_Attr_ViewLayer_Tag_Tag],
            
            LayerLens_AttrSec_UIStackView_Axis: @[LayerLens_Attr_UIStackView_Axis_Axis],
            
            LayerLens_AttrSec_UIStackView_Distribution: @[LayerLens_Attr_UIStackView_Distribution_Distribution],
            
            LayerLens_AttrSec_UIStackView_Alignment: @[LayerLens_Attr_UIStackView_Alignment_Alignment],
            
            LayerLens_AttrSec_UIStackView_Spacing: @[LayerLens_Attr_UIStackView_Spacing_Spacing],
            
            LayerLens_AttrSec_UIVisualEffectView_Style: @[LayerLens_Attr_UIVisualEffectView_Style_Style],
            
            LayerLens_AttrSec_UIVisualEffectView_QMUIForegroundColor: @[LayerLens_Attr_UIVisualEffectView_QMUIForegroundColor_Color],
            
            LayerLens_AttrSec_UIImageView_Name: @[LayerLens_Attr_UIImageView_Name_Name],
            
            LayerLens_AttrSec_UIImageView_Open: @[LayerLens_Attr_UIImageView_Open_Open],
            
            LayerLens_AttrSec_UILabel_Font: @[LayerLens_Attr_UILabel_Font_Name,
                                          LayerLens_Attr_UILabel_Font_Size],
            
            LayerLens_AttrSec_UILabel_NumberOfLines: @[LayerLens_Attr_UILabel_NumberOfLines_NumberOfLines],
            
            LayerLens_AttrSec_UILabel_Text: @[LayerLens_Attr_UILabel_Text_Text],
            
            LayerLens_AttrSec_UILabel_TextColor: @[LayerLens_Attr_UILabel_TextColor_Color],
            
            LayerLens_AttrSec_UILabel_BreakMode: @[LayerLens_Attr_UILabel_BreakMode_Mode],
            
            LayerLens_AttrSec_UILabel_Alignment: @[LayerLens_Attr_UILabel_Alignment_Alignment],
            
            LayerLens_AttrSec_UILabel_CanAdjustFont: @[LayerLens_Attr_UILabel_CanAdjustFont_CanAdjustFont],
            
            LayerLens_AttrSec_UIControl_EnabledSelected: @[LayerLens_Attr_UIControl_EnabledSelected_Enabled,
                                                       LayerLens_Attr_UIControl_EnabledSelected_Selected],
            
            LayerLens_AttrSec_UIControl_QMUIOutsideEdge: @[LayerLens_Attr_UIControl_QMUIOutsideEdge_Edge],
            
            LayerLens_AttrSec_UIControl_VerAlignment: @[LayerLens_Attr_UIControl_VerAlignment_Alignment],
            
            LayerLens_AttrSec_UIControl_HorAlignment: @[LayerLens_Attr_UIControl_HorAlignment_Alignment],
            
            LayerLens_AttrSec_UIButton_ContentInsets: @[LayerLens_Attr_UIButton_ContentInsets_Insets],
            
            LayerLens_AttrSec_UIButton_TitleInsets: @[LayerLens_Attr_UIButton_TitleInsets_Insets],
            
            LayerLens_AttrSec_UIButton_ImageInsets: @[LayerLens_Attr_UIButton_ImageInsets_Insets],
            
            LayerLens_AttrSec_UIScrollView_ContentInset: @[LayerLens_Attr_UIScrollView_ContentInset_Inset],
            
            LayerLens_AttrSec_UIScrollView_AdjustedInset: @[LayerLens_Attr_UIScrollView_AdjustedInset_Inset],
            
            LayerLens_AttrSec_UIScrollView_QMUIInitialInset: @[LayerLens_Attr_UIScrollView_QMUIInitialInset_Inset],
            
            LayerLens_AttrSec_UIScrollView_IndicatorInset: @[LayerLens_Attr_UIScrollView_IndicatorInset_Inset],
            
            LayerLens_AttrSec_UIScrollView_Offset: @[LayerLens_Attr_UIScrollView_Offset_Offset],
            
            LayerLens_AttrSec_UIScrollView_ContentSize: @[LayerLens_Attr_UIScrollView_ContentSize_Size],
            
            LayerLens_AttrSec_UIScrollView_Behavior: @[LayerLens_Attr_UIScrollView_Behavior_Behavior],
            
            LayerLens_AttrSec_UIScrollView_ShowsIndicator: @[LayerLens_Attr_UIScrollView_ShowsIndicator_Hor,
                                                         LayerLens_Attr_UIScrollView_ShowsIndicator_Ver],
            
            LayerLens_AttrSec_UIScrollView_Bounce: @[LayerLens_Attr_UIScrollView_Bounce_Hor,
                                                 LayerLens_Attr_UIScrollView_Bounce_Ver],
            
            LayerLens_AttrSec_UIScrollView_ScrollPaging: @[LayerLens_Attr_UIScrollView_ScrollPaging_ScrollEnabled,
                                                       LayerLens_Attr_UIScrollView_ScrollPaging_PagingEnabled],
            
            LayerLens_AttrSec_UIScrollView_ContentTouches: @[LayerLens_Attr_UIScrollView_ContentTouches_Delay,
                                                         LayerLens_Attr_UIScrollView_ContentTouches_CanCancel],
            
            LayerLens_AttrSec_UIScrollView_Zoom: @[LayerLens_Attr_UIScrollView_Zoom_Bounce,
                                               LayerLens_Attr_UIScrollView_Zoom_Scale,
                                               LayerLens_Attr_UIScrollView_Zoom_MinScale,
                                               LayerLens_Attr_UIScrollView_Zoom_MaxScale],
            
            LayerLens_AttrSec_UITableView_Style: @[LayerLens_Attr_UITableView_Style_Style],
            
            LayerLens_AttrSec_UITableView_SectionsNumber: @[LayerLens_Attr_UITableView_SectionsNumber_Number],
            
            LayerLens_AttrSec_UITableView_RowsNumber: @[LayerLens_Attr_UITableView_RowsNumber_Number],
            
            LayerLens_AttrSec_UITableView_SeparatorInset: @[LayerLens_Attr_UITableView_SeparatorInset_Inset],
            
            LayerLens_AttrSec_UITableView_SeparatorColor: @[LayerLens_Attr_UITableView_SeparatorColor_Color],
            
            LayerLens_AttrSec_UITableView_SeparatorStyle: @[LayerLens_Attr_UITableView_SeparatorStyle_Style],
            
            LayerLens_AttrSec_UITextView_Basic: @[LayerLens_Attr_UITextView_Basic_Editable,
                                              LayerLens_Attr_UITextView_Basic_Selectable],
            
            LayerLens_AttrSec_UITextView_Text: @[LayerLens_Attr_UITextView_Text_Text],
            
            LayerLens_AttrSec_UITextView_Font: @[LayerLens_Attr_UITextView_Font_Name,
                                             LayerLens_Attr_UITextView_Font_Size],
            
            LayerLens_AttrSec_UITextView_TextColor: @[LayerLens_Attr_UITextView_TextColor_Color],
            
            LayerLens_AttrSec_UITextView_Alignment: @[LayerLens_Attr_UITextView_Alignment_Alignment],
            
            LayerLens_AttrSec_UITextView_ContainerInset: @[LayerLens_Attr_UITextView_ContainerInset_Inset],
            
            LayerLens_AttrSec_UITextField_Text: @[LayerLens_Attr_UITextField_Text_Text],
            
            LayerLens_AttrSec_UITextField_Placeholder: @[LayerLens_Attr_UITextField_Placeholder_Placeholder],
            
            LayerLens_AttrSec_UITextField_Font: @[LayerLens_Attr_UITextField_Font_Name,
                                              LayerLens_Attr_UITextField_Font_Size],
            
            LayerLens_AttrSec_UITextField_TextColor: @[LayerLens_Attr_UITextField_TextColor_Color],
            
            LayerLens_AttrSec_UITextField_Alignment: @[LayerLens_Attr_UITextField_Alignment_Alignment],
            
            LayerLens_AttrSec_UITextField_Clears: @[LayerLens_Attr_UITextField_Clears_ClearsOnBeginEditing,
                                                LayerLens_Attr_UITextField_Clears_ClearsOnInsertion],
            
            LayerLens_AttrSec_UITextField_CanAdjustFont: @[LayerLens_Attr_UITextField_CanAdjustFont_CanAdjustFont,
                                                       LayerLens_Attr_UITextField_CanAdjustFont_MinSize],
            
            LayerLens_AttrSec_UITextField_ClearButtonMode: @[LayerLens_Attr_UITextField_ClearButtonMode_Mode]
        };
    });
    return dict[sectionID];
}

+ (void)getHostGroupID:(inout LayerLens_AttrGroupIdentifier *)groupID_inout sectionID:(inout LayerLens_AttrSectionIdentifier *)sectionID_inout fromAttrID:(LayerLens_AttrIdentifier)targetAttrID {
    __block LayerLens_AttrGroupIdentifier targetGroupID = nil;
    __block LayerLens_AttrSectionIdentifier targetSecID = nil;
    [[self groupIDs] enumerateObjectsUsingBlock:^(LayerLens_AttrGroupIdentifier _Nonnull groupID, NSUInteger idx, BOOL * _Nonnull stop0) {
        [[self sectionIDsForGroupID:groupID] enumerateObjectsUsingBlock:^(LayerLens_AttrSectionIdentifier _Nonnull secID, NSUInteger idx, BOOL * _Nonnull stop1) {
            [[self attrIDsForSectionID:secID] enumerateObjectsUsingBlock:^(LayerLens_AttrIdentifier _Nonnull attrID, NSUInteger idx, BOOL * _Nonnull stop2) {
                if ([attrID isEqualToString:targetAttrID]) {
                    targetGroupID = groupID;
                    targetSecID = secID;
                    *stop0 = YES;
                    *stop1 = YES;
                    *stop2 = YES;
                }
            }];
        }];
    }];
    
    if (groupID_inout && targetGroupID) {
        *groupID_inout = targetGroupID;
    }
    if (sectionID_inout && targetSecID) {
        *sectionID_inout = targetSecID;
    }
}

+ (NSString *)groupTitleWithGroupID:(LayerLens_AttrGroupIdentifier)groupID {
    static dispatch_once_t onceToken;
    static NSDictionary *rawInfo = nil;
    dispatch_once(&onceToken,^{
        rawInfo = @{
            LayerLens_AttrGroup_Class: @"Class",
            LayerLens_AttrGroup_Relation: @"Relation",
            LayerLens_AttrGroup_Layout: @"Layout",
            LayerLens_AttrGroup_AutoLayout: @"AutoLayout",
            LayerLens_AttrGroup_ViewLayer: @"CALayer / UIView",
            LayerLens_AttrGroup_UIImageView: @"UIImageView",
            LayerLens_AttrGroup_UILabel: @"UILabel",
            LayerLens_AttrGroup_UIControl: @"UIControl",
            LayerLens_AttrGroup_UIButton: @"UIButton",
            LayerLens_AttrGroup_UIScrollView: @"UIScrollView",
            LayerLens_AttrGroup_UITableView: @"UITableView",
            LayerLens_AttrGroup_UITextView: @"UITextView",
            LayerLens_AttrGroup_UITextField: @"UITextField",
            LayerLens_AttrGroup_UIVisualEffectView: @"UIVisualEffectView",
            LayerLens_AttrGroup_UIStackView: @"UIStackView"
        };
    });
    NSString *title = rawInfo[groupID];
    NSAssert(title.length, @"");
    return title;
}

+ (NSString *)sectionTitleWithSectionID:(LayerLens_AttrSectionIdentifier)secID {
    static dispatch_once_t onceToken;
    static NSDictionary *rawInfo = nil;
    dispatch_once(&onceToken,^{
        rawInfo = @{
            LayerLens_AttrSec_Layout_Frame: @"Frame",
            LayerLens_AttrSec_Layout_Bounds: @"Bounds",
            LayerLens_AttrSec_Layout_SafeArea: @"SafeArea",
            LayerLens_AttrSec_Layout_Position: @"Position",
            LayerLens_AttrSec_Layout_AnchorPoint: @"AnchorPoint",
            LayerLens_AttrSec_AutoLayout_Hugging: @"HuggingPriority",
            LayerLens_AttrSec_AutoLayout_Resistance: @"ResistancePriority",
            LayerLens_AttrSec_AutoLayout_IntrinsicSize: @"IntrinsicSize",
            LayerLens_AttrSec_ViewLayer_Corner: @"CornerRadius",
            LayerLens_AttrSec_ViewLayer_BgColor: @"BackgroundColor",
            LayerLens_AttrSec_ViewLayer_Border: @"Border",
            LayerLens_AttrSec_ViewLayer_Shadow: @"Shadow",
            LayerLens_AttrSec_ViewLayer_ContentMode: @"ContentMode",
            LayerLens_AttrSec_ViewLayer_TintColor: @"TintColor",
            LayerLens_AttrSec_ViewLayer_Tag: @"Tag",
            LayerLens_AttrSec_UIStackView_Axis: @"Axis",
            LayerLens_AttrSec_UIStackView_Distribution: @"Distribution",
            LayerLens_AttrSec_UIStackView_Alignment: @"Alignment",
            LayerLens_AttrSec_UIVisualEffectView_Style: @"Style",
            LayerLens_AttrSec_UIVisualEffectView_QMUIForegroundColor: @"ForegroundColor",
            LayerLens_AttrSec_UIImageView_Name: @"ImageName",
            LayerLens_AttrSec_UILabel_TextColor: @"TextColor",
            LayerLens_AttrSec_UITextView_TextColor: @"TextColor",
            LayerLens_AttrSec_UITextField_TextColor: @"TextColor",
            LayerLens_AttrSec_UILabel_BreakMode: @"LineBreakMode",
            LayerLens_AttrSec_UILabel_NumberOfLines: @"NumberOfLines",
            LayerLens_AttrSec_UILabel_Text: @"Text",
            LayerLens_AttrSec_UITextView_Text: @"Text",
            LayerLens_AttrSec_UITextField_Text: @"Text",
            LayerLens_AttrSec_UITextField_Placeholder: @"Placeholder",
            LayerLens_AttrSec_UILabel_Alignment: @"TextAlignment",
            LayerLens_AttrSec_UITextView_Alignment: @"TextAlignment",
            LayerLens_AttrSec_UITextField_Alignment: @"TextAlignment",
            LayerLens_AttrSec_UIControl_HorAlignment: @"HorizontalAlignment",
            LayerLens_AttrSec_UIControl_VerAlignment: @"VerticalAlignment",
            LayerLens_AttrSec_UIControl_QMUIOutsideEdge: @"QMUI_outsideEdge",
            LayerLens_AttrSec_UIButton_ContentInsets: @"ContentInsets",
            LayerLens_AttrSec_UIButton_TitleInsets: @"TitleInsets",
            LayerLens_AttrSec_UIButton_ImageInsets: @"ImageInsets",
            LayerLens_AttrSec_UIScrollView_QMUIInitialInset: @"QMUI_initialContentInset",
            LayerLens_AttrSec_UIScrollView_ContentInset: @"ContentInset",
            LayerLens_AttrSec_UIScrollView_AdjustedInset: @"AdjustedContentInset",
            LayerLens_AttrSec_UIScrollView_IndicatorInset: @"ScrollIndicatorInsets",
            LayerLens_AttrSec_UIScrollView_Offset: @"ContentOffset",
            LayerLens_AttrSec_UIScrollView_ContentSize: @"ContentSize",
            LayerLens_AttrSec_UIScrollView_Behavior: @"InsetAdjustmentBehavior",
            LayerLens_AttrSec_UIScrollView_ShowsIndicator: @"ShowsScrollIndicator",
            LayerLens_AttrSec_UIScrollView_Bounce: @"AlwaysBounce",
            LayerLens_AttrSec_UIScrollView_Zoom: @"Zoom",
            LayerLens_AttrSec_UITableView_Style: @"Style",
            LayerLens_AttrSec_UITableView_SectionsNumber: @"NumberOfSections",
            LayerLens_AttrSec_UITableView_RowsNumber: @"NumberOfRows",
            LayerLens_AttrSec_UITableView_SeparatorColor: @"SeparatorColor",
            LayerLens_AttrSec_UITableView_SeparatorInset: @"SeparatorInset",
            LayerLens_AttrSec_UITableView_SeparatorStyle: @"SeparatorStyle",
            LayerLens_AttrSec_UILabel_Font: @"Font",
            LayerLens_AttrSec_UITextField_Font: @"Font",
            LayerLens_AttrSec_UITextView_Font: @"Font",
            LayerLens_AttrSec_UITextView_ContainerInset: @"ContainerInset",
            LayerLens_AttrSec_UITextField_ClearButtonMode: @"ClearButtonMode",
        };
    });
    return rawInfo[secID];
}

/**
 className: 必填项，标识该属性是哪一个类拥有的
 
 fullTitle: 完整的名字，将作为搜索的 keywords，也会展示在搜索结果中，如果为 nil 则不会被搜索到
 
 briefTitle：简略的名字，仅 checkbox 和那种自带标题的 input 才需要这个属性，如果需要该属性但该属性又为空，则会读取 fullTitle
 
 setterString：用户试图修改属性值时会用到，若该字段为空字符串（即 @“”）则该属性不可修改，若该字段为 nil 则会在 fullTitle 的基础上自动生成（自动改首字母大小写、加前缀后缀，比如 alpha 会被转换为 setAlpha:）
 
 getterString：必填项，业务中读取属性值时会用到。如果该字段为 nil ，则会在 fullTitle 的基础上自动生成（自动把 fullTitle 的第一个字母改成小写，比如 Alpha 会被转换为 alpha）。如果该字段为空字符串（比如 image_open_open）则属性值会被固定为 nil，attrType 会被指为 LayerLens_AttrTypeCustomObj
 
 typeIfObj：当某个 LayerLens_Attribute 确定是 NSObject 类型时，该方法返回它具体是什么对象，比如 UIColor、NSString
 
 enumList：如果某个 attribute 是 enum，则这里标识了相应的 enum 的名称（如 "NSTextAlignment"），业务可通过这个名称进而查询可用的枚举值列表
 
 patch：如果为 YES，则用户修改了该 Attribute 的值后，Lookin 会重新拉取和更新相关图层的位置、截图等信息，如果为 nil 则默认是 NO
 
 hideIfNil：如果为 YES，则当获取的 value 为 nil 时，Lookin 不会传输该 attr。如果为 NO，则即使 value 为 nil 也会传输（比如 label 的 text 属性，即使它是 nil 我们也要显示，所以它的 hideIfNil 应该为 NO）。如果该字段为 nil 则默认是 NO
 
 osVersion: 该属性需要的最低的 iOS 版本，比如 safeAreaInsets 从 iOS 11.0 开始出现，则该属性应该为 @11，如果为 nil 则表示不限制 iOS 版本
 
 */
+ (NSDictionary<NSString *, id> *)_infoForAttrID:(LayerLens_AttrIdentifier)attrID {
    static NSDictionary<LayerLens_AttrIdentifier, NSDictionary<NSString *, id> *> *dict;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{
        dict = @{
            LayerLens_Attr_Class_Class_Class: @{
                @"className": @"CALayer",
                @"getterString": @"layerlens_relatedClassChainList",
                @"setterString": @"",
                @"typeIfObj": @(LayerLens_AttrTypeCustomObj)
            },
            
            LayerLens_Attr_Relation_Relation_Relation: @{
                @"className": @"CALayer",
                @"getterString": @"layerlens_selfRelation",
                @"setterString": @"",
                @"typeIfObj": @(LayerLens_AttrTypeCustomObj),
                @"hideIfNil": @(YES)
            },
            
            LayerLens_Attr_Layout_Frame_Frame: @{
                @"className": @"CALayer",
                @"fullTitle": @"Frame",
                @"patch": @(YES)
            },
            LayerLens_Attr_Layout_Bounds_Bounds: @{
                @"className": @"CALayer",
                @"fullTitle": @"Bounds",
                @"patch": @(YES)
            },
            LayerLens_Attr_Layout_SafeArea_SafeArea: @{
                @"className": @"UIView",
                @"fullTitle": @"SafeAreaInsets",
                @"setterString": @"",
                @"osVersion": @(11)
            },
            LayerLens_Attr_Layout_Position_Position: @{
                @"className": @"CALayer",
                @"fullTitle": @"Position",
                @"patch": @(YES)
            },
            LayerLens_Attr_Layout_AnchorPoint_AnchorPoint: @{
                @"className": @"CALayer",
                @"fullTitle": @"AnchorPoint",
                @"patch": @(YES)
            },
            
            LayerLens_Attr_AutoLayout_Hugging_Hor: @{
                @"className": @"UIView",
                @"fullTitle": @"ContentHuggingPriority(Horizontal)",
                @"getterString": @"layerlens_horizontalContentHuggingPriority",
                @"setterString": @"setLayerlens_horizontalContentHuggingPriority:",
                @"briefTitle": @"H",
                @"patch": @(YES)
            },
            LayerLens_Attr_AutoLayout_Hugging_Ver: @{
                @"className": @"UIView",
                @"fullTitle": @"ContentHuggingPriority(Vertical)",
                @"getterString": @"layerlens_verticalContentHuggingPriority",
                @"setterString": @"setLayerlens_verticalContentHuggingPriority:",
                @"briefTitle": @"V",
                @"patch": @(YES)
            },
            LayerLens_Attr_AutoLayout_Resistance_Hor: @{
                @"className": @"UIView",
                @"fullTitle": @"ContentCompressionResistancePriority(Horizontal)",
                @"getterString": @"layerlens_horizontalContentCompressionResistancePriority",
                @"setterString": @"setLayerlens_horizontalContentCompressionResistancePriority:",
                @"briefTitle": @"H",
                @"patch": @(YES)
            },
            LayerLens_Attr_AutoLayout_Resistance_Ver: @{
                @"className": @"UIView",
                @"fullTitle": @"ContentCompressionResistancePriority(Vertical)",
                @"getterString": @"layerlens_verticalContentCompressionResistancePriority",
                @"setterString": @"setLayerlens_verticalContentCompressionResistancePriority:",
                @"briefTitle": @"V",
                @"patch": @(YES)
            },
            LayerLens_Attr_AutoLayout_Constraints_Constraints: @{
                @"className": @"UIView",
                @"getterString": @"layerlens_constraints",
                @"setterString": @"",
                @"typeIfObj": @(LayerLens_AttrTypeCustomObj),
                @"hideIfNil": @(YES)
            },
            LayerLens_Attr_AutoLayout_IntrinsicSize_Size: @{
                @"className": @"UIView",
                @"fullTitle": @"IntrinsicContentSize",
                @"setterString": @""
            },
            
            LayerLens_Attr_ViewLayer_Visibility_Hidden: @{
                @"className": @"CALayer",
                @"fullTitle": @"Hidden",
                @"getterString": @"isHidden",
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_Visibility_Opacity: @{
                @"className": @"CALayer",
                @"fullTitle": @"Opacity / Alpha",
                @"setterString": @"setOpacity:",
                @"getterString": @"opacity",
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_InterationAndMasks_Interaction: @{
                @"className": @"UIView",
                @"fullTitle": @"UserInteractionEnabled",
                @"getterString": @"isUserInteractionEnabled",
                @"patch": @(NO)
            },
            LayerLens_Attr_ViewLayer_InterationAndMasks_MasksToBounds: @{
                @"className": @"CALayer",
                @"fullTitle": @"MasksToBounds / ClipsToBounds",
                @"briefTitle": @"MasksToBounds",
                @"setterString": @"setMasksToBounds:",
                @"getterString": @"masksToBounds",
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_Corner_Radius: @{
                @"className": @"CALayer",
                @"fullTitle": @"CornerRadius",
                @"briefTitle": @"",
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_BgColor_BgColor: @{
                @"className": @"CALayer",
                @"fullTitle": @"BackgroundColor",
                @"setterString": @"setLayerlens_backgroundColor:",
                @"getterString": @"layerlens_backgroundColor",
                @"typeIfObj": @(LayerLens_AttrTypeUIColor),
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_Border_Color: @{
                @"className": @"CALayer",
                @"fullTitle": @"BorderColor",
                @"setterString": @"setLayerlens_borderColor:",
                @"getterString": @"layerlens_borderColor",
                @"typeIfObj": @(LayerLens_AttrTypeUIColor),
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_Border_Width: @{
                @"className": @"CALayer",
                @"fullTitle": @"BorderWidth",
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_Shadow_Color: @{
                @"className": @"CALayer",
                @"fullTitle": @"ShadowColor",
                @"setterString": @"setLayerlens_shadowColor:",
                @"getterString": @"layerlens_shadowColor",
                @"typeIfObj": @(LayerLens_AttrTypeUIColor),
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_Shadow_Opacity: @{
                @"className": @"CALayer",
                @"fullTitle": @"ShadowOpacity",
                @"briefTitle": @"Opacity",
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_Shadow_Radius: @{
                @"className": @"CALayer",
                @"fullTitle": @"ShadowRadius",
                @"briefTitle": @"Radius",
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_Shadow_OffsetW: @{
                @"className": @"CALayer",
                @"fullTitle": @"ShadowOffsetWidth",
                @"briefTitle": @"OffsetW",
                @"setterString": @"setLayerlens_shadowOffsetWidth:",
                @"getterString": @"layerlens_shadowOffsetWidth",
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_Shadow_OffsetH: @{
                @"className": @"CALayer",
                @"fullTitle": @"ShadowOffsetHeight",
                @"briefTitle": @"OffsetH",
                @"setterString": @"setLayerlens_shadowOffsetHeight:",
                @"getterString": @"layerlens_shadowOffsetHeight",
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_ContentMode_Mode: @{
                @"className": @"UIView",
                @"fullTitle": @"ContentMode",
                @"enumList": @"UIViewContentMode",
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_TintColor_Color: @{
                @"className": @"UIView",
                @"fullTitle": @"TintColor",
                @"typeIfObj": @(LayerLens_AttrTypeUIColor),
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_TintColor_Mode: @{
                @"className": @"UIView",
                @"fullTitle": @"TintAdjustmentMode",
                @"enumList": @"UIViewTintAdjustmentMode",
                @"patch": @(YES)
            },
            LayerLens_Attr_ViewLayer_Tag_Tag: @{
                @"className": @"UIView",
                @"fullTitle": @"Tag",
                @"briefTitle": @"",
                @"patch": @(NO)
            },
            
            LayerLens_Attr_UIStackView_Axis_Axis: @{
                @"className": @"UIStackView",
                @"fullTitle": @"Axis",
                @"enumList": @"UILayoutConstraintAxis",
                @"patch": @(YES)
            },
            
            LayerLens_Attr_UIStackView_Distribution_Distribution: @{
                @"className": @"UIStackView",
                @"fullTitle": @"Distribution",
                @"enumList": @"UIStackViewDistribution",
                @"patch": @(YES)
            },
            
            LayerLens_Attr_UIStackView_Alignment_Alignment: @{
                @"className": @"UIStackView",
                @"fullTitle": @"Alignment",
                @"enumList": @"UIStackViewAlignment",
                @"patch": @(YES)
            },
            
            LayerLens_Attr_UIStackView_Spacing_Spacing: @{
                @"className": @"UIStackView",
                @"fullTitle": @"Spacing",
                @"patch": @(YES)
            },
            
            LayerLens_Attr_UIVisualEffectView_Style_Style: @{
                @"className": @"UIVisualEffectView",
                @"setterString": @"setLayerlens_blurEffectStyleNumber:",
                @"getterString": @"layerlens_blurEffectStyleNumber",
                @"enumList": @"UIBlurEffectStyle",
                @"typeIfObj": @(LayerLens_AttrTypeCustomObj),
                @"patch": @(YES),
                @"hideIfNil": @(YES)
            },
            
            LayerLens_Attr_UIVisualEffectView_QMUIForegroundColor_Color: @{
                @"className": @"QMUIVisualEffectView",
                @"fullTitle": @"ForegroundColor",
                @"typeIfObj": @(LayerLens_AttrTypeUIColor),
                @"patch": @(YES),
            },
            
            LayerLens_Attr_UIImageView_Name_Name: @{
                @"className": @"UIImageView",
                @"fullTitle": @"ImageName",
                @"setterString": @"",
                @"getterString": @"layerlens_imageSourceName",
                @"typeIfObj": @(LayerLens_AttrTypeNSString),
                @"hideIfNil": @(YES)
            },
            LayerLens_Attr_UIImageView_Open_Open: @{
                @"className": @"UIImageView",
                @"setterString": @"",
                @"getterString": @"layerlens_imageViewOidIfHasImage",
                @"typeIfObj": @(LayerLens_AttrTypeCustomObj),
                @"hideIfNil": @(YES)
            },
            
            LayerLens_Attr_UILabel_Text_Text: @{
                @"className": @"UILabel",
                @"fullTitle": @"Text",
                @"typeIfObj": @(LayerLens_AttrTypeNSString),
                @"patch": @(YES)
            },
            LayerLens_Attr_UILabel_NumberOfLines_NumberOfLines: @{
                @"className": @"UILabel",
                @"fullTitle": @"NumberOfLines",
                @"briefTitle": @"",
                @"patch": @(YES)
            },
            LayerLens_Attr_UILabel_Font_Size: @{
                @"className": @"UILabel",
                @"fullTitle": @"FontSize",
                @"briefTitle": @"FontSize",
                @"setterString": @"setLayerlens_fontSize:",
                @"getterString": @"layerlens_fontSize",
                @"patch": @(YES)
            },
            LayerLens_Attr_UILabel_Font_Name: @{
                @"className": @"UILabel",
                @"fullTitle": @"FontName",
                @"setterString": @"",
                @"getterString": @"layerlens_fontName",
                @"typeIfObj": @(LayerLens_AttrTypeNSString),
                @"patch": @(NO)
            },
            LayerLens_Attr_UILabel_TextColor_Color: @{
                @"className": @"UILabel",
                @"fullTitle": @"TextColor",
                @"typeIfObj": @(LayerLens_AttrTypeUIColor),
                @"patch": @(YES)
            },
            LayerLens_Attr_UILabel_Alignment_Alignment: @{
                @"className": @"UILabel",
                @"fullTitle": @"TextAlignment",
                @"enumList": @"NSTextAlignment",
                @"patch": @(YES)
            },
            LayerLens_Attr_UILabel_BreakMode_Mode: @{
                @"className": @"UILabel",
                @"fullTitle": @"LineBreakMode",
                @"enumList": @"NSLineBreakMode",
                @"patch": @(YES)
            },
            LayerLens_Attr_UILabel_CanAdjustFont_CanAdjustFont: @{
                @"className": @"UILabel",
                @"fullTitle": @"AdjustsFontSizeToFitWidth",
                @"patch": @(YES)
            },
            
            LayerLens_Attr_UIControl_EnabledSelected_Enabled: @{
                @"className": @"UIControl",
                @"fullTitle": @"Enabled",
                @"getterString": @"isEnabled",
                @"patch": @(NO)
            },
            LayerLens_Attr_UIControl_EnabledSelected_Selected: @{
                @"className": @"UIControl",
                @"fullTitle": @"Selected",
                @"getterString": @"isSelected",
                @"patch": @(YES)
            },
            LayerLens_Attr_UIControl_VerAlignment_Alignment: @{
                @"className": @"UIControl",
                @"fullTitle": @"ContentVerticalAlignment",
                @"enumList": @"UIControlContentVerticalAlignment",
                @"patch": @(YES)
            },
            LayerLens_Attr_UIControl_HorAlignment_Alignment: @{
                @"className": @"UIControl",
                @"fullTitle": @"ContentHorizontalAlignment",
                @"enumList": @"UIControlContentHorizontalAlignment",
                @"patch": @(YES)
            },
            LayerLens_Attr_UIControl_QMUIOutsideEdge_Edge: @{
                @"className": @"UIControl",
                @"fullTitle": @"qmui_outsideEdge"
            },
            
            LayerLens_Attr_UIButton_ContentInsets_Insets: @{
                @"className": @"UIButton",
                @"fullTitle": @"ContentEdgeInsets",
                @"patch": @(YES)
            },
            LayerLens_Attr_UIButton_TitleInsets_Insets: @{
                @"className": @"UIButton",
                @"fullTitle": @"TitleEdgeInsets",
                @"patch": @(YES)
            },
            LayerLens_Attr_UIButton_ImageInsets_Insets: @{
                @"className": @"UIButton",
                @"fullTitle": @"ImageEdgeInsets",
                @"patch": @(YES)
            },
            
            LayerLens_Attr_UIScrollView_Offset_Offset: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"ContentOffset",
                @"patch": @(YES)
            },
            LayerLens_Attr_UIScrollView_ContentSize_Size: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"ContentSize",
                @"patch": @(YES)
            },
            LayerLens_Attr_UIScrollView_ContentInset_Inset: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"ContentInset",
                @"patch": @(YES)
            },
            LayerLens_Attr_UIScrollView_QMUIInitialInset_Inset: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"qmui_initialContentInset",
                @"patch": @(YES)
            },
            LayerLens_Attr_UIScrollView_AdjustedInset_Inset: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"AdjustedContentInset",
                @"setterString": @"",
                @"osVersion": @(11)
            },
            LayerLens_Attr_UIScrollView_Behavior_Behavior: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"ContentInsetAdjustmentBehavior",
                @"enumList": @"UIScrollViewContentInsetAdjustmentBehavior",
                @"patch": @(YES),
                @"osVersion": @(11)
            },
            LayerLens_Attr_UIScrollView_IndicatorInset_Inset: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"ScrollIndicatorInsets",
                @"patch": @(NO)
            },
            LayerLens_Attr_UIScrollView_ScrollPaging_ScrollEnabled: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"ScrollEnabled",
                @"getterString": @"isScrollEnabled",
                @"patch": @(NO)
            },
            LayerLens_Attr_UIScrollView_ScrollPaging_PagingEnabled: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"PagingEnabled",
                @"getterString": @"isPagingEnabled",
                @"patch": @(NO)
            },
            LayerLens_Attr_UIScrollView_Bounce_Ver: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"AlwaysBounceVertical",
                @"briefTitle": @"Vertical",
                @"patch": @(NO)
            },
            LayerLens_Attr_UIScrollView_Bounce_Hor: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"AlwaysBounceHorizontal",
                @"briefTitle": @"Horizontal",
                @"patch": @(NO)
            },
            LayerLens_Attr_UIScrollView_ShowsIndicator_Hor: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"ShowsHorizontalScrollIndicator",
                @"briefTitle": @"Horizontal",
                @"patch": @(NO)
            },
            LayerLens_Attr_UIScrollView_ShowsIndicator_Ver: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"ShowsVerticalScrollIndicator",
                @"briefTitle": @"Vertical",
                @"patch": @(NO)
            },
            LayerLens_Attr_UIScrollView_ContentTouches_Delay: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"DelaysContentTouches",
                @"patch": @(NO)
            },
            LayerLens_Attr_UIScrollView_ContentTouches_CanCancel: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"CanCancelContentTouches",
                @"patch": @(NO)
            },
            LayerLens_Attr_UIScrollView_Zoom_MinScale: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"MinimumZoomScale",
                @"briefTitle": @"MinScale",
                @"patch": @(NO)
            },
            LayerLens_Attr_UIScrollView_Zoom_MaxScale: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"MaximumZoomScale",
                @"briefTitle": @"MaxScale",
                @"patch": @(NO)
            },
            LayerLens_Attr_UIScrollView_Zoom_Scale: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"ZoomScale",
                @"briefTitle": @"Scale",
                @"patch": @(YES)
            },
            LayerLens_Attr_UIScrollView_Zoom_Bounce: @{
                @"className": @"UIScrollView",
                @"fullTitle": @"BouncesZoom",
                @"patch": @(NO)
            },
            
            LayerLens_Attr_UITableView_Style_Style: @{
                @"className": @"UITableView",
                @"fullTitle": @"Style",
                @"setterString": @"",
                @"enumList": @"UITableViewStyle",
                @"patch": @(YES)
            },
            LayerLens_Attr_UITableView_SectionsNumber_Number: @{
                @"className": @"UITableView",
                @"fullTitle": @"NumberOfSections",
                @"setterString": @"",
                @"patch": @(YES)
            },
            LayerLens_Attr_UITableView_RowsNumber_Number: @{
                @"className": @"UITableView",
                @"setterString": @"",
                @"getterString": @"layerlens_numberOfRows",
                @"typeIfObj": @(LayerLens_AttrTypeCustomObj)
            },
            LayerLens_Attr_UITableView_SeparatorInset_Inset: @{
                @"className": @"UITableView",
                @"fullTitle": @"SeparatorInset",
                @"patch": @(NO)
            },
            LayerLens_Attr_UITableView_SeparatorColor_Color: @{
                @"className": @"UITableView",
                @"fullTitle": @"SeparatorColor",
                @"typeIfObj": @(LayerLens_AttrTypeUIColor),
                @"patch": @(YES)
            },
            LayerLens_Attr_UITableView_SeparatorStyle_Style: @{
                @"className": @"UITableView",
                @"fullTitle": @"SeparatorStyle",
                @"enumList": @"UITableViewCellSeparatorStyle",
                @"patch": @(YES)
            },
            
            LayerLens_Attr_UITextView_Text_Text: @{
                @"className": @"UITextView",
                @"fullTitle": @"Text",
                @"typeIfObj": @(LayerLens_AttrTypeNSString),
                @"patch": @(YES)
            },
            LayerLens_Attr_UITextView_Font_Name: @{
                @"className": @"UITextView",
                @"fullTitle": @"FontName",
                @"setterString": @"",
                @"getterString": @"layerlens_fontName",
                @"typeIfObj": @(LayerLens_AttrTypeNSString),
                @"patch": @(NO)
            },
            LayerLens_Attr_UITextView_Font_Size: @{
                @"className": @"UITextView",
                @"fullTitle": @"FontSize",
                @"setterString": @"setLayerlens_fontSize:",
                @"getterString": @"layerlens_fontSize",
                @"patch": @(YES)
            },
            LayerLens_Attr_UITextView_Basic_Editable: @{
                @"className": @"UITextView",
                @"fullTitle": @"Editable",
                @"getterString": @"isEditable",
                @"patch": @(NO)
            },
            LayerLens_Attr_UITextView_Basic_Selectable: @{
                @"className": @"UITextView",
                @"fullTitle": @"Selectable",
                @"getterString": @"isSelectable",
                @"patch": @(NO)
            },
            LayerLens_Attr_UITextView_TextColor_Color: @{
                @"className": @"UITextView",
                @"fullTitle": @"TextColor",
                @"typeIfObj": @(LayerLens_AttrTypeUIColor),
                @"patch": @(YES)
            },
            LayerLens_Attr_UITextView_Alignment_Alignment: @{
                @"className": @"UITextView",
                @"fullTitle": @"TextAlignment",
                @"enumList": @"NSTextAlignment",
                @"patch": @(YES)
            },
            LayerLens_Attr_UITextView_ContainerInset_Inset: @{
                @"className": @"UITextView",
                @"fullTitle": @"TextContainerInset",
                @"patch": @(YES)
            },
            
            LayerLens_Attr_UITextField_Font_Name: @{
                @"className": @"UITextField",
                @"fullTitle": @"FontName",
                @"setterString": @"",
                @"getterString": @"layerlens_fontName",
                @"typeIfObj": @(LayerLens_AttrTypeNSString),
                @"patch": @(NO)
            },
            LayerLens_Attr_UITextField_Font_Size: @{
                @"className": @"UITextField",
                @"fullTitle": @"FontSize",
                @"setterString": @"setLayerlens_fontSize:",
                @"getterString": @"layerlens_fontSize",
                @"patch": @(YES)
            },
            LayerLens_Attr_UITextField_TextColor_Color: @{
                @"className": @"UITextField",
                @"fullTitle": @"TextColor",
                @"typeIfObj": @(LayerLens_AttrTypeUIColor),
                @"patch": @(YES)
            },
            LayerLens_Attr_UITextField_Alignment_Alignment: @{
                @"className": @"UITextField",
                @"fullTitle": @"TextAlignment",
                @"enumList": @"NSTextAlignment",
                @"patch": @(YES)
            },
            LayerLens_Attr_UITextField_Text_Text: @{
                @"className": @"UITextField",
                @"fullTitle": @"Text",
                @"typeIfObj": @(LayerLens_AttrTypeNSString),
                @"patch": @(YES)
            },
            LayerLens_Attr_UITextField_Placeholder_Placeholder: @{
                @"className": @"UITextField",
                @"fullTitle": @"Placeholder",
                @"typeIfObj": @(LayerLens_AttrTypeNSString),
                @"patch": @(YES)
            },
            LayerLens_Attr_UITextField_Clears_ClearsOnBeginEditing: @{
                @"className": @"UITextField",
                @"fullTitle": @"ClearsOnBeginEditing",
                @"patch": @(NO)
            },
            LayerLens_Attr_UITextField_Clears_ClearsOnInsertion: @{
                @"className": @"UITextField",
                @"fullTitle": @"ClearsOnInsertion",
                @"patch": @(NO)
            },
            LayerLens_Attr_UITextField_CanAdjustFont_CanAdjustFont: @{
                @"className": @"UITextField",
                @"fullTitle": @"AdjustsFontSizeToFitWidth",
                @"patch": @(YES)
            },
            LayerLens_Attr_UITextField_CanAdjustFont_MinSize: @{
                @"className": @"UITextField",
                @"fullTitle": @"MinimumFontSize",
                @"patch": @(YES)
            },
            LayerLens_Attr_UITextField_ClearButtonMode_Mode: @{
                @"className": @"UITextField",
                @"fullTitle": @"ClearButtonMode",
                @"enumList": @"UITextFieldViewMode",
                @"patch": @(NO)
            },
        };
    });
    
    NSDictionary<NSString *, id> *targetInfo = dict[attrID];
    return targetInfo;
}

+ (LayerLens_AttrType)objectAttrTypeWithAttrID:(LayerLens_AttrIdentifier)attrID {
    NSDictionary<NSString *, id> *attrInfo = [self _infoForAttrID:attrID];
    NSNumber *typeIfObj = attrInfo[@"typeIfObj"];
    return [typeIfObj integerValue];
}

+ (NSString *)classNameWithAttrID:(LayerLens_AttrIdentifier)attrID {
    NSDictionary<NSString *, id> *attrInfo = [self _infoForAttrID:attrID];
    NSString *className = attrInfo[@"className"];
    
    NSAssert(className.length > 0, @"");
    
    return className;
}

+ (BOOL)isUIViewPropertyWithAttrID:(LayerLens_AttrIdentifier)attrID {
    NSString *className = [self classNameWithAttrID:attrID];
    
    if ([className isEqualToString:@"CALayer"]) {
        return NO;
    }
    return YES;
}

+ (NSString *)enumListNameWithAttrID:(LayerLens_AttrIdentifier)attrID {
    NSDictionary<NSString *, id> *attrInfo = [self _infoForAttrID:attrID];
    NSString *name = attrInfo[@"enumList"];
    return name;
}

+ (BOOL)needPatchAfterModificationWithAttrID:(LayerLens_AttrIdentifier)attrID {
    NSDictionary<NSString *, id> *attrInfo = [self _infoForAttrID:attrID];
    NSNumber *needPatch = attrInfo[@"patch"];
    return [needPatch boolValue];
}

+ (NSString *)fullTitleWithAttrID:(LayerLens_AttrIdentifier)attrID {
    NSDictionary<NSString *, id> *attrInfo = [self _infoForAttrID:attrID];
    NSString *fullTitle = attrInfo[@"fullTitle"];
    return fullTitle;
}

+ (NSString *)briefTitleWithAttrID:(LayerLens_AttrIdentifier)attrID {
    NSDictionary<NSString *, id> *attrInfo = [self _infoForAttrID:attrID];
    NSString *briefTitle = attrInfo[@"briefTitle"];
    if (!briefTitle) {
        briefTitle = attrInfo[@"fullTitle"];
    }
    return briefTitle;
}

+ (SEL)getterWithAttrID:(LayerLens_AttrIdentifier)attrID {
    NSDictionary<NSString *, id> *attrInfo = [self _infoForAttrID:attrID];
    NSString *getterString = attrInfo[@"getterString"];
    if (getterString && getterString.length == 0) {
        // 空字符串，比如 image_open_open
        return nil;
    }
    if (!getterString) {
        NSString *fullTitle = attrInfo[@"fullTitle"];
        NSAssert(fullTitle.length > 0, @"");
        
        getterString = [NSString stringWithFormat:@"%@%@", [fullTitle substringToIndex:1].lowercaseString, [fullTitle substringFromIndex:1]].copy;
    }
    return NSSelectorFromString(getterString);
}

+ (SEL)setterWithAttrID:(LayerLens_AttrIdentifier)attrID {
    NSDictionary<NSString *, id> *attrInfo = [self _infoForAttrID:attrID];
    NSString *setterString = attrInfo[@"setterString"];
    if ([setterString isEqualToString:@""]) {
        // 该属性不可在 Lookin 客户端中被修改
        return nil;
    }
    if (!setterString) {
        NSString *fullTitle = attrInfo[@"fullTitle"];
        NSAssert(fullTitle.length > 0, @"");
        
        setterString = [NSString stringWithFormat:@"set%@%@:", [fullTitle substringToIndex:1].uppercaseString, [fullTitle substringFromIndex:1]];
    }
    return NSSelectorFromString(setterString);
}

+ (BOOL)hideIfNilWithAttrID:(LayerLens_AttrIdentifier)attrID {
    NSDictionary<NSString *, id> *attrInfo = [self _infoForAttrID:attrID];
    NSNumber *boolValue = attrInfo[@"hideIfNil"];
    return boolValue.boolValue;
}

+ (NSInteger)minAvailableOSVersionWithAttrID:(LayerLens_AttrIdentifier)attrID {
    NSDictionary<NSString *, id> *attrInfo = [self _infoForAttrID:attrID];
    NSNumber *minVerNum = attrInfo[@"osVersion"];
    NSInteger minVer = [minVerNum integerValue];
    return minVer;
}

@end

