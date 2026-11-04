// Owns a read-only decoded PSD. Keys describe complete paths and duplicate siblings.
// Rendering accepts visibility overrides, never changes or saves the source archive.
unit SYNC_MusicStudio_PsdLayers;

interface

uses System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  System.Types, Vcl.Graphics, SYNC_MusicStudio_ArtDocument, SYNC_MusicStudio_DrumPsdRules, SYNC_MusicStudio_InstrumentRules;

type
  TMusicStudioLayerInfo = record
    Key, ParentKey, Name, Path, Group: string;
    Visible, IsGroup: Boolean;
    Bounds: TRect;
    SourceIndex: Integer;
  end;
  TMusicStudioLayerDocument = class
  private
    FDocument: TArtDocument;
    FFilePath, FLastError: string;
    FLayers: TArray<TMusicStudioLayerInfo>;
    FByKey: TDictionary<string,TArtLayer>;
    FParents: TDictionary<string,string>;
    FImages: TObjectDictionary<string,TBitmap>;
    FCacheBytes: Int64;
    FLoadCount, FRenderCount: Integer;
    FDrumRules: TMusicStudioDrumPsdRules;
    FInstrumentRules: TMusicStudioInstrumentRules;
    procedure BuildLayers(AnalyzeDrums: Boolean = True);
    procedure Clear;
    function GetLoaded: Boolean;
    function GetWidth: Integer;
    function GetHeight: Integer;
    function GetCacheCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    // Failed loads clear earlier decoded data, retaining an explanatory LastError.
    function LoadFile(const Path: string): Boolean;
    // Copies metadata and shares immutable channel arrays; safe for a worker's lifetime.
    function Clone: TMusicStudioLayerDocument;
    // Keyは完全パスと同名兄弟を識別する安定キー。検索結果のレイヤー配列はDocument所有。
    function HasLayer(const Key: string): Boolean;
    function LayerIndex(const Key: string): Integer;
    // 呼出元所有のOverridesへ祖先の表示指定を追加する。読込済みPSDの初期状態は変更しない。
    procedure RequireVisibleAncestors(Overrides: TJSONObject; const Key: string);
    // Honors PSDTool '*' exclusivity at the selected layer and every opened ancestor.
    procedure SelectLayerOverride(Overrides: TJSONObject; const Key: string);
    // 母音自身の初期表示を除き、現在の表情で親の枝が表示されているかを確認する。
    function LayerBranchVisible(const Key: string; Overrides: TJSONObject): Boolean;
    // Target/Overridesは借用。成功時はTargetへpremultiplied BGRAを出力し、内部cacheを更新する。
    // 失敗時はLastErrorを設定する。原PSDの保存や共有設定の変更は行わない。
    function Render(Target: TBitmap; Overrides: TJSONObject = nil; MaximumDimension: Integer = 0; const ScaleKey: string = ''; PartScale: Double = 1): Boolean;
    property Loaded: Boolean read GetLoaded;
    property FilePath: string read FFilePath;
    property LastError: string read FLastError;
    property Width: Integer read GetWidth;
    property Height: Integer read GetHeight;
    property Layers: TArray<TMusicStudioLayerInfo> read FLayers;
    property LoadCount: Integer read FLoadCount;
    property RenderCount: Integer read FRenderCount;
    property CacheCount: Integer read GetCacheCount;
    property DrumRules: TMusicStudioDrumPsdRules read FDrumRules;
    property InstrumentRules: TMusicStudioInstrumentRules read FInstrumentRules;
  end;

// 呼出元所有のObjの指定キーだけを置き換える。nilは何もせず、Objを解放しない。
procedure MusicStudioSetJsonBoolean(Obj: TJSONObject; const Key: string; Value: Boolean);

implementation

uses SYNC_MusicStudio_LayerScale, System.Math, SYNC_MusicStudio_ArtPsd, SYNC_MusicStudio_ArtLayerName;

const MAX_RENDER_CACHE_BYTES = Int64(64)*1024*1024;
  MAX_RENDER_CACHE_ITEMS = 8;

procedure MusicStudioSetJsonBoolean(Obj: TJSONObject; const Key: string; Value: Boolean);
var Pair: TJSONPair;
begin
  if Obj=nil then Exit;
  Pair := Obj.RemovePair(Key); Pair.Free;
  Obj.AddPair(Key,TJSONBool.Create(Value));
end;

constructor TMusicStudioLayerDocument.Create;
begin
  inherited;
  FByKey := TDictionary<string,TArtLayer>.Create;
  FParents := TDictionary<string,string>.Create;
  FImages := TObjectDictionary<string,TBitmap>.Create([doOwnsValues]);
  FDrumRules := TMusicStudioDrumPsdRules.Create;
  FInstrumentRules := TMusicStudioInstrumentRules.Create;
end;

destructor TMusicStudioLayerDocument.Destroy;
begin
  Clear; FInstrumentRules.Free; FDrumRules.Free; FImages.Free; FParents.Free; FByKey.Free; inherited;
end;

procedure TMusicStudioLayerDocument.Clear;
begin
  FImages.Clear; FCacheBytes := 0; FByKey.Clear; FParents.Clear;
  FLayers := nil; FreeAndNil(FDocument); FLastError := '';
  if FDrumRules<>nil then FDrumRules.Clear;
  if FInstrumentRules<>nil then FInstrumentRules.Clear;
end;

function TMusicStudioLayerDocument.GetLoaded: Boolean;
begin Result := FDocument<>nil; end;
function TMusicStudioLayerDocument.GetWidth: Integer;
begin Result := 0; if Loaded then Result := FDocument.Width; end;
function TMusicStudioLayerDocument.GetHeight: Integer;
begin Result := 0; if Loaded then Result := FDocument.Height; end;
function TMusicStudioLayerDocument.GetCacheCount: Integer;
begin Result := FImages.Count; end;

procedure TMusicStudioLayerDocument.BuildLayers(AnalyzeDrums: Boolean);
var Items: TList<TMusicStudioLayerInfo>; DrumLayers: TArray<TDrumPsdLayer>; I: Integer;
  procedure Walk(List: TList<TArtLayer>; const ParentKey, ParentPath: string; Depth: Integer);
  var Ordinals: TDictionary<string,Integer>; Layer: TArtLayer;
      Info: TMusicStudioLayerInfo; Ordinal: Integer;
  begin
    if Depth>128 then raise EArtFormat.Create('PSDの階層が深すぎます。');
    Ordinals := TDictionary<string,Integer>.Create;
    try
      for Layer in List do begin
        if Layer.Kind=alkDivider then Continue;
        if not Ordinals.TryGetValue(Layer.Name,Ordinal) then Ordinal := 0;
        Inc(Ordinal); Ordinals.AddOrSetValue(Layer.Name,Ordinal);
        Info := Default(TMusicStudioLayerInfo);
        Info.Key := ParentKey+'/'+IntToStr(Length(Layer.Name))+':'+Layer.Name+'#'+IntToStr(Ordinal);
        Info.Name := Layer.Name; Info.Path := ParentPath+'/'+Layer.Name;
        Info.Group := ParentPath; Info.ParentKey := ParentKey; Info.Visible := Layer.Visible;
        Info.IsGroup := Layer.Kind=alkGroup; Info.SourceIndex := Layer.SourceIndex;
        Info.Bounds := Rect(Layer.Bounds.Left,Layer.Bounds.Top,Layer.Bounds.Right,Layer.Bounds.Bottom);
        Items.Add(Info); FByKey.Add(Info.Key,Layer); FParents.Add(Info.Key,ParentKey);
        Walk(Layer.Children,Info.Key,Info.Path,Depth+1);
      end;
    finally Ordinals.Free; end;
  end;
begin
  FByKey.Clear; FParents.Clear; Items := TList<TMusicStudioLayerInfo>.Create;
  try Walk(FDocument.Roots,'','',0); FLayers := Items.ToArray;
  finally Items.Free; end;
  if AnalyzeDrums then begin
    SetLength(DrumLayers,Length(FLayers));
    for I := 0 to High(FLayers) do begin
      DrumLayers[I].Key := FLayers[I].Key; FParents.TryGetValue(FLayers[I].Key,DrumLayers[I].ParentKey);
      DrumLayers[I].Name := FLayers[I].Name; DrumLayers[I].Path := FLayers[I].Path;
      DrumLayers[I].IsGroup := FLayers[I].IsGroup; DrumLayers[I].Visible := FLayers[I].Visible;
      DrumLayers[I].SourceIndex := FLayers[I].SourceIndex;
    end;
    FDrumRules.Build(DrumLayers);
    FInstrumentRules.Build(DrumLayers);
  end;
end;

function TMusicStudioLayerDocument.LoadFile(const Path: string): Boolean;
begin
  Clear; FFilePath := Path; Result := False;
  try
    if Trim(Path)='' then raise EArtFormat.Create('PSDが未選択です。');
    if not FileExists(Path) then raise EArtFormat.Create('PSDの参照ファイルが見つかりません。');
    if not SameText(ExtractFileExt(Path),'.psd') then raise EArtFormat.Create('PSDファイルを指定してください。');
    Inc(FLoadCount); FDocument := ReadPsd(Path); BuildLayers; Result := True;
  except on E: Exception do begin
    FLastError := E.Message; FImages.Clear; FByKey.Clear; FParents.Clear;
    FLayers := nil; FreeAndNil(FDocument);
    FDrumRules.Clear;
    FInstrumentRules.Clear;
  end; end;
end;

function TMusicStudioLayerDocument.Clone: TMusicStudioLayerDocument;
begin
  Result := TMusicStudioLayerDocument.Create;
  try
    Result.FFilePath := FFilePath; Result.FLastError := FLastError;
    if Loaded then begin
      Result.FDocument := FDocument.Clone; Result.BuildLayers(False);
      Result.FDrumRules.Free; Result.FDrumRules := nil; Result.FDrumRules := FDrumRules.Clone;
      Result.FInstrumentRules.Free; Result.FInstrumentRules := nil; Result.FInstrumentRules := FInstrumentRules.Clone;
    end;
  except Result.Free; raise; end;
end;

function TMusicStudioLayerDocument.HasLayer(const Key: string): Boolean;
begin Result := FByKey.ContainsKey(Key); end;
function TMusicStudioLayerDocument.LayerIndex(const Key: string): Integer;
var I: Integer;
begin
  Result := -1;
  for I := 0 to High(FLayers) do if FLayers[I].Key=Key then Exit(I);
end;

procedure TMusicStudioLayerDocument.RequireVisibleAncestors(Overrides: TJSONObject; const Key: string);
var Parent, NextParent: string;
begin
  if (Overrides=nil) or not HasLayer(Key) then Exit;
  Parent := Key;
  while Parent<>'' do begin
    MusicStudioSetJsonBoolean(Overrides,Parent,True);
    if not FParents.TryGetValue(Parent,NextParent) then Break;
    Parent := NextParent;
  end;
end;

procedure TMusicStudioLayerDocument.SelectLayerOverride(Overrides: TJSONObject; const Key: string);
var Layer: TArtLayer; Current,Parent,SiblingParent: string; Info: TMusicStudioLayerInfo;
begin
  if (Overrides=nil) or not HasLayer(Key) then Exit;
  Current := Key;
  while Current<>'' do begin
    if not FByKey.TryGetValue(Current,Layer) or not FParents.TryGetValue(Current,Parent) then Break;
    if Pos('*',ParseLayerName(Layer.Name).Prefix)>0 then
      for Info in FLayers do
        if (Info.Key<>Current) and (Pos('*',ParseLayerName(Info.Name).Prefix)>0) and
           FParents.TryGetValue(Info.Key,SiblingParent) and (SiblingParent=Parent) then
          MusicStudioSetJsonBoolean(Overrides,Info.Key,False);
    MusicStudioSetJsonBoolean(Overrides,Current,True);
    Current := Parent;
  end;
end;

function TMusicStudioLayerDocument.LayerBranchVisible(const Key: string; Overrides: TJSONObject): Boolean;
var Current,Parent: string; L: TArtLayer; Value: TJSONValue;
begin
  Result := HasLayer(Key); if not Result then Exit; Current := Key;
  while FParents.TryGetValue(Current,Parent) and (Parent<>'') do begin
    if not FByKey.TryGetValue(Parent,L) then Exit(False);
    Value := nil; if Overrides<>nil then Value := Overrides.GetValue(Parent);
    if Value is TJSONBool then begin if not TJSONBool(Value).AsBoolean then Exit(False); end
    else if not L.Visible then Exit(False);
    Current := Parent;
  end;
end;
function TMusicStudioLayerDocument.Render(Target: TBitmap; Overrides: TJSONObject; MaximumDimension: Integer; const ScaleKey: string; PartScale: Double): Boolean;
var Key,VisibilityKey: string; Cache: TBitmap; Snapshot: TMusicStudioLayerDocument;
    Info: TMusicStudioLayerInfo; Value: TJSONValue; Layer: TArtLayer;
    Pixels: TBytes; Row: PByte; X,Y,P,A,W,H: Integer; Factor: Double;
begin
  Result := False; FLastError := '';
  if Target=nil then begin FLastError := '表示先がありません。'; Exit; end;
  if not Loaded then begin FLastError := 'PSDが読み込まれていません。'; Exit; end;
  Snapshot := nil; Cache := nil;
  try
    Factor := 1; if MaximumDimension>0 then Factor := Min(1.0,MaximumDimension/Max(Width,Height));
    W := Max(1,Round(Width*Factor)); H := Max(1,Round(Height*Factor));
    VisibilityKey := '';
    for Info in FLayers do begin
      Value := nil; if Overrides<>nil then Value := Overrides.GetValue(Info.Key);
      if (Value<>nil) and not (Value is TJSONBool) then
        raise EArtFormat.Create('PSDレイヤーの表示設定が不正です。');
      if Value=nil then begin if Info.Visible then VisibilityKey := VisibilityKey+'1' else VisibilityKey := VisibilityKey+'0'; end
      else if TJSONBool(Value).AsBoolean then VisibilityKey := VisibilityKey+'1' else VisibilityKey := VisibilityKey+'0';
    end;
    Key := IntToStr(W)+'x'+IntToStr(H)+':'+VisibilityKey+'|'+ScaleKey+'|'+FloatToStr(PartScale,TFormatSettings.Invariant);
    if FImages.TryGetValue(Key,Cache) then begin Target.Assign(Cache); Exit(True); end;
    Snapshot := Clone;
    for X := 0 to High(FLayers) do begin
      Layer := Snapshot.FByKey[FLayers[X].Key]; Layer.Visible := VisibilityKey[X+1]='1';
    end;
    if (ScaleKey<>'') and Snapshot.FByKey.TryGetValue(ScaleKey,Layer) then ScaleMusicStudioArtLayer(Layer,PartScale);
    Inc(FRenderCount); Pixels := RenderPsdLayers(Snapshot.FDocument,W,H);
    Cache := TBitmap.Create; Cache.PixelFormat := pf32bit;
    Cache.SetSize(W,H); Cache.AlphaFormat := afPremultiplied;
    for Y := 0 to H-1 do begin
      Row := Cache.ScanLine[Y];
      for X := 0 to W-1 do begin
        P := (Y*W+X)*4; A := Pixels[P+3];
        Row[X*4] := (Integer(Pixels[P+2])*A+127) div 255;
        Row[X*4+1] := (Integer(Pixels[P+1])*A+127) div 255;
        Row[X*4+2] := (Integer(Pixels[P])*A+127) div 255;
        Row[X*4+3] := A;
      end;
    end;
    Target.Assign(Cache);
    if (FImages.Count>=MAX_RENDER_CACHE_ITEMS) or
       (FCacheBytes+Int64(W)*H*4>MAX_RENDER_CACHE_BYTES) then begin
      FImages.Clear; FCacheBytes := 0;
    end;
    if Int64(W)*H*4<=MAX_RENDER_CACHE_BYTES then begin
      FImages.Add(Key,Cache); Inc(FCacheBytes,Int64(W)*H*4); Cache := nil;
    end;
    Result := True;
  except on E: Exception do FLastError := E.Message; end;
  Snapshot.Free;
  // A borrowed cached entry belongs to FImages; only newly generated images reach here.
  Cache.Free;
end;

end.
