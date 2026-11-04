library SYNC_LipSync;

// 口パクのAviUtl2 DLL境界。

{$ALIGN 8}

uses
  AviUtl2FilterTypes in 'Source\Lib\AviUtl2FilterTypes.pas',
  SYNC_MusicStudio_DarkTheme in 'Source\Lib\SYNC_MusicStudio_DarkTheme.pas',
  PluginFilterTable in 'Source\Lib\FilterTable\PluginFilterTable.pas',
  SYNC_MusicStudio_AudioWaveform in 'Source\Common\Audio\SYNC_MusicStudio_AudioWaveform.pas',
  SYNC_MusicStudio_ArtDocument in 'Source\Common\Render\Layers\Model\SYNC_MusicStudio_ArtDocument.pas',
  SYNC_MusicStudio_ArtLayerName in 'Source\Common\Render\Layers\Model\SYNC_MusicStudio_ArtLayerName.pas',
  SYNC_MusicStudio_ArtPsd in 'Source\Common\Render\Layers\Model\SYNC_MusicStudio_ArtPsd.pas',
  SYNC_MusicStudio_ArtPsdOrigin in 'Source\Common\Render\Layers\Model\SYNC_MusicStudio_ArtPsdOrigin.pas',
  SYNC_MusicStudio_DrumPsdRules in 'Source\Common\Render\Layers\Rules\SYNC_MusicStudio_DrumPsdRules.pas',
  SYNC_MusicStudio_InstrumentRules in 'Source\Common\Render\Layers\Rules\SYNC_MusicStudio_InstrumentRules.pas',
  SYNC_MusicStudio_LayerScale in 'Source\Common\Render\Layers\Rules\SYNC_MusicStudio_LayerScale.pas',
  SYNC_MusicStudio_PsdLayerConfig in 'Source\Common\Render\Layers\Rules\SYNC_MusicStudio_PsdLayerConfig.pas',
  SYNC_MusicStudio_PsdLayers in 'Source\Common\Render\Layers\SYNC_MusicStudio_PsdLayers.pas',
  SYNC_MusicStudio_FramebufferCapture in 'Source\Common\Render\Host\SYNC_MusicStudio_FramebufferCapture.pas',
  SYNC_MusicStudio_HostBackground in 'Source\Common\Render\Host\SYNC_MusicStudio_HostBackground.pas',
  SYNC_MusicStudio_SingingData in 'Source\Common\Singing\SYNC_MusicStudio_SingingData.pas',
  SYNC_MusicStudio_SingingFormats in 'Source\Common\Singing\SYNC_MusicStudio_SingingFormats.pas',
  SYNC_MusicStudio_Vowels in 'Source\Common\Singing\SYNC_MusicStudio_Vowels.pas',
  SYNC_MusicStudio_PsdTransform in 'Source\Common\Render\Placement\SYNC_MusicStudio_PsdTransform.pas',
  SYNC_LipSync_PreviewViewport in 'Source\Plugin\Filter\Preview\SYNC_LipSync_PreviewViewport.pas',
  SYNC_LipSync_Scene in 'Source\Common\Render\Scene\SYNC_LipSync_Scene.pas',
  SYNC_LipSync_SettingsForm in 'Source\Plugin\Filter\PSD\SYNC_LipSync_SettingsForm.pas' {FormLipSyncSettings},
  SYNC_LipSync_Project in 'Source\Common\Project\SYNC_LipSync_Project.pas',
  SYNC_MusicStudio_BeatData in 'Source\Common\Timing\SYNC_MusicStudio_BeatData.pas',
  SYNC_MusicStudio_MeterMap in 'Source\Common\Timing\SYNC_MusicStudio_MeterMap.pas',
  SYNC_MusicStudio_PreviewPlayback in 'Source\Common\Audio\SYNC_MusicStudio_PreviewPlayback.pas',
  SYNC_LipSync_TimelineView in 'Source\Plugin\Filter\Timeline\SYNC_LipSync_TimelineView.pas',
  SYNC_LipSync_EditHistory in 'Source\Common\Project\SYNC_LipSync_EditHistory.pas',
  SYNC_LipSync_TempoEditor in 'Source\Plugin\Filter\Timeline\SYNC_LipSync_TempoEditor.pas',
  SYNC_LipSync_ArrangementForm in 'Source\Plugin\Filter\Arrangement\SYNC_LipSync_ArrangementForm.pas',
  SYNC_LipSync_Presentation in 'Source\Common\Motion\SYNC_LipSync_Presentation.pas',
  SYNC_MusicStudio_MotionData in 'Source\Common\Motion\SYNC_MusicStudio_MotionData.pas',
  SYNC_LipSync_ExpressionForm in 'Source\Plugin\Filter\PSD\SYNC_LipSync_ExpressionForm.pas',
  SYNC_LipSync_FilterPlugin in 'Source\Plugin\Filter\SYNC_LipSync_FilterPlugin.pas';

{$R *.res}

function InitializePlugin(Version: Cardinal): Byte; cdecl;
begin
  Result := 0;
  try
    SetLipSyncHostVersion(Version);
    GetLipSyncFilterTable;
    Result := 1;
  except
    // Delphi例外をAviUtl2のCコールバック境界へ漏らさない。
  end;
end;

procedure UninitializePlugin; cdecl;
begin
end;

function GetFilterPluginTable: PFILTER_PLUGIN_TABLE; cdecl;
begin
  Result := nil;
  try
    Result := GetLipSyncFilterTable;
  except
    // 登録失敗時はテーブルを返さずホスト側へ判断を委ねる。
  end;
end;

exports
  InitializePlugin name 'InitializePlugin',
  UninitializePlugin name 'UninitializePlugin',
  GetFilterPluginTable name 'GetFilterPluginTable';

begin
end.
