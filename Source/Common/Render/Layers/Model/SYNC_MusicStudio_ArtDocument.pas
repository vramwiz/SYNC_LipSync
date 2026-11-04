// Copied from AviUtl2PluginLib/Lib/PSDArtEditor/Core/ArtDocument.pas.
// Read and render only through SYNC_MusicStudio_PsdLayers; source PSD files are never saved.
unit SYNC_MusicStudio_ArtDocument;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.Generics.Collections;

type
  EArtFormat = class(Exception);
  TArtLayerKind = (alkImage, alkGroup, alkDivider);
  TArtBounds = record
    Left, Top, Right, Bottom: Integer;
    class function Create(ALeft, ATop, ARight, ABottom: Integer): TArtBounds; static;
    function Width: Integer;
    function Height: Integer;
  end;
  TArtLayer = class
  public
    Id, Name: string;
    Kind: TArtLayerKind;
    Bounds: TArtBounds;
    HasMask, MaskDisabled, MaskInvert: Boolean;
    MaskBounds: TArtBounds; // Absolute canvas coordinates; separate from image bounds.
    MaskDefault: Byte;
    MaskPixels: TBytes; // Top-down single-channel coverage.
    Pixels: TBytes; // Top-down, straight-alpha RGBA8. Never VCL pixel storage.
    Children: TList<TArtLayer>; // Non-owning, topmost first.
    Visible: Boolean;
    Opacity: Byte;
    BlendKey: AnsiString;
    Clipping: Byte;
    SectionType: Cardinal;
    SourceIndex: Integer;
    constructor Create;
    destructor Destroy; override;
  end;
  TArtDocument = class
  private
    FOwnedLayers: TObjectList<TArtLayer>;
    procedure ValidateStructure(ForRender: Boolean);
    function LayerLocation(Layer: TArtLayer; out Depth: Integer): TList<TArtLayer>;
    procedure CheckLayerPlacement(Layer, Parent: TArtLayer);
  public
    SessionId: string;
    Revision: UInt64;
    Width, Height: Integer;
    Roots: TList<TArtLayer>; // Non-owning, topmost first.
    SourceBytes: TBytes; // Owned archive; independent of original file lifetime.
    MergedPlanes: TArray<TBytes>;
    MergedHasTransparency: Boolean;
    SourceRecordCount: Integer;
    Unsupported: TStringList;
    constructor Create;
    destructor Destroy; override;
    function AddLayer(AKind: TArtLayerKind; const AName: string;
      const ABounds: TArtBounds; Parent: TArtLayer = nil): TArtLayer;
    function NewUnattachedLayer: TArtLayer;
    procedure RemoveNewLayer(Layer: TArtLayer);
    function Clone: TArtDocument;
    function FindLayer(const LayerId: string): TArtLayer;
    // Index is the final, zero-based sibling position after removing Layer.
    // These operations preserve layer identity/content; the editor advances Revision.
    function MoveLayer(Layer, Parent: TArtLayer; Index: Integer): Boolean;
    function SwapLayers(Layer, Other: TArtLayer): Boolean;
    // Remove an image or a complete group subtree. At least one root must remain.
    // Source archive indices of surviving layers are preserved; the editor advances Revision.
    procedure DeleteLayer(Layer: TArtLayer);
    procedure Changed;
    procedure ValidateForNewSave;
    // Output size samples the same canvas pixels as nearest-neighbour reduction of a full render.
    // Layer/mask coordinates remain in the original PSD; zero keeps the native dimensions.
    function RenderRGBA(OutputWidth: Integer = 0; OutputHeight: Integer = 0): TBytes;
  end;

const
  ART_MAX_PIXELS = 16000000; // Initial allocation limit, not PSD format limit.
  ART_MAX_BYTES = 536870912;

function PixelByteCount(Width, Height, Channels: Integer): Integer;
// Comparisons ignore transient sessions/revisions. Pixel arrays are immutable assets.
function SameArtDocumentContent(A, B: TArtDocument): Boolean;
function SameArtDocumentVisualContent(A, B: TArtDocument): Boolean;
function SameArtDocumentVisibility(A, B: TArtDocument): Boolean;
function SameArtDocumentStructure(A, B: TArtDocument): Boolean;

implementation

uses System.Math;

type TArtCompareMode = (acContent, acVisual, acVisibility, acStructure);

function SameArtBytes(const A, B: TBytes): Boolean;
begin
  Result := Length(A) = Length(B);
  if Result and (Length(A) > 0) and (@A[0] <> @B[0]) then
    Result := CompareMem(@A[0], @B[0], Length(A));
end;

function SameArtLayers(Left, Right: TList<TArtLayer>; Mode: TArtCompareMode;
  Depth: Integer): Boolean;
var J: Integer; L, R: TArtLayer;
begin
  Result := False;
  if Left.Count <> Right.Count then Exit;
  if Left.Count = 0 then Exit(True);
  if Depth > 128 then Exit;
  for J := 0 to Left.Count - 1 do begin
    L := Left[J]; R := Right[J];
    if (L = nil) or (R = nil) or (L.Kind <> R.Kind) then Exit;
    if (Mode in [acContent, acStructure]) and (L.SourceIndex <> R.SourceIndex) then Exit;
    if (Mode = acStructure) and (L.SourceIndex < 0) and (L.Id <> R.Id) then Exit;
    if (Mode <> acStructure) and (L.Visible <> R.Visible) then Exit;
    if (Mode = acContent) and (L.Name <> R.Name) then Exit;
    if Mode in [acContent, acVisual] then
      if (L.Opacity <> R.Opacity) or (L.BlendKey <> R.BlendKey) or
         (L.Clipping <> R.Clipping) or (L.SectionType <> R.SectionType) or
         not CompareMem(@L.Bounds, @R.Bounds, SizeOf(TArtBounds)) or
         (L.HasMask <> R.HasMask) or (L.MaskDisabled <> R.MaskDisabled) or
         (L.MaskInvert <> R.MaskInvert) or (L.MaskDefault <> R.MaskDefault) or
         not CompareMem(@L.MaskBounds, @R.MaskBounds, SizeOf(TArtBounds)) or
         not SameArtBytes(L.Pixels, R.Pixels) or
         not SameArtBytes(L.MaskPixels, R.MaskPixels) then Exit;
    if not SameArtLayers(L.Children, R.Children, Mode, Depth + 1) then Exit;
  end;
  Result := True;
end;

function SameArtDocumentContent(A, B: TArtDocument): Boolean;
var I: Integer;
begin
  if A = B then Exit(True);
  if (A = nil) or (B = nil) then Exit(False);
  Result := False;
  if (A.Width <> B.Width) or (A.Height <> B.Height) or
     (A.SourceRecordCount <> B.SourceRecordCount) or
     (A.MergedHasTransparency <> B.MergedHasTransparency) or
     (A.Unsupported.Text <> B.Unsupported.Text) or
     (Length(A.MergedPlanes) <> Length(B.MergedPlanes)) or
     not SameArtBytes(A.SourceBytes, B.SourceBytes) then Exit;
  for I := 0 to High(A.MergedPlanes) do
    if not SameArtBytes(A.MergedPlanes[I], B.MergedPlanes[I]) then Exit;
  Result := SameArtLayers(A.Roots, B.Roots, acContent, 0);
end;

function SameArtDocumentVisualContent(A, B: TArtDocument): Boolean;
begin
  if A = B then Exit(True);
  if (A = nil) or (B = nil) then Exit(False);
  Result := (A.Width = B.Width) and (A.Height = B.Height) and
    (A.Unsupported.Text = B.Unsupported.Text) and
    SameArtLayers(A.Roots, B.Roots, acVisual, 0);
end;

function SameArtDocumentVisibility(A, B: TArtDocument): Boolean;
begin
  if A = B then Exit(True);
  if (A = nil) or (B = nil) then Exit(False);
  Result := SameArtLayers(A.Roots, B.Roots, acVisibility, 0);
end;

function SameArtDocumentStructure(A, B: TArtDocument): Boolean;
begin
  if A = B then Exit(True);
  if (A = nil) or (B = nil) then Exit(False);
  Result := SameArtLayers(A.Roots, B.Roots, acStructure, 0);
end;


function PixelByteCount(Width, Height, Channels: Integer): Integer;
var N: Int64;
begin
  if (Width < 0) or (Height < 0) or (Channels < 1) then
    raise EArtFormat.Create('Negative image dimensions');
  N := Int64(Width) * Height;
  if (N > ART_MAX_PIXELS) or (N * Channels > ART_MAX_BYTES) then
    raise EArtFormat.Create('Image allocation limit exceeded');
  Result := Integer(N * Channels);
end;

class function TArtBounds.Create(ALeft, ATop, ARight, ABottom: Integer): TArtBounds;
begin
  Result.Left := ALeft; Result.Top := ATop;
  Result.Right := ARight; Result.Bottom := ABottom;
end;

function TArtBounds.Width: Integer;
var N: Int64;
begin
  N := Int64(Right) - Left;
  if (N < 0) or (N > High(Integer)) then raise EArtFormat.Create('Invalid layer width');
  Result := Integer(N);
end;

function TArtBounds.Height: Integer;
var N: Int64;
begin
  N := Int64(Bottom) - Top;
  if (N < 0) or (N > High(Integer)) then raise EArtFormat.Create('Invalid layer height');
  Result := Integer(N);
end;

constructor TArtLayer.Create;
var G: TGUID;
begin
  inherited;
  CreateGUID(G); Id := GUIDToString(G);
  Children := TList<TArtLayer>.Create;
  Visible := True; Opacity := 255; BlendKey := 'norm'; SourceIndex := -1;
end;

destructor TArtLayer.Destroy;
begin
  Children.Free;
  inherited;
end;

constructor TArtDocument.Create;
var G: TGUID;
begin
  inherited;
  CreateGUID(G); SessionId := GUIDToString(G); Revision := 0;
  FOwnedLayers := TObjectList<TArtLayer>.Create(True);
  Roots := TList<TArtLayer>.Create;
  Unsupported := TStringList.Create;
end;

destructor TArtDocument.Destroy;
begin
  Unsupported.Free; Roots.Free; FOwnedLayers.Free;
  inherited;
end;

function TArtDocument.NewUnattachedLayer: TArtLayer;
begin
  Result := TArtLayer.Create;
  FOwnedLayers.Add(Result);
end;

function TArtDocument.AddLayer(AKind: TArtLayerKind; const AName: string;
  const ABounds: TArtBounds; Parent: TArtLayer): TArtLayer;
begin
  if Assigned(Parent) and ((Parent.Kind <> alkGroup) or not FOwnedLayers.Contains(Parent)) then
    raise EArtFormat.Create('Invalid parent');
  Result := NewUnattachedLayer;
  Result.Kind := AKind; Result.Name := AName; Result.Bounds := ABounds;
  if AKind = alkGroup then begin Result.BlendKey := 'pass'; Result.SectionType := 1; end;
  if Assigned(Parent) then Parent.Children.Add(Result) else Roots.Add(Result);
end;

procedure TArtDocument.RemoveNewLayer(Layer: TArtLayer);
  procedure Detach(List: TList<TArtLayer>);
  var L: TArtLayer;
  begin
    List.Remove(Layer);
    for L in List do Detach(L.Children);
  end;
begin
  if (Layer=nil) or (Layer.SourceIndex<>-1) or (Layer.Children.Count<>0) then raise EArtFormat.Create('Only new leaf rollback supported');
  Detach(Roots); FOwnedLayers.Remove(Layer);
end;

procedure TArtDocument.Changed;
begin
  if Revision=High(UInt64) then raise EArtFormat.Create('Document revision exhausted');
  Inc(Revision);
end;
function TArtDocument.FindLayer(const LayerId: string): TArtLayer;
var L: TArtLayer;
begin
  Result := nil;
  for L in FOwnedLayers do if L.Id=LayerId then Exit(L);
end;

function TArtDocument.LayerLocation(Layer: TArtLayer; out Depth: Integer): TList<TArtLayer>;
  function Find(List: TList<TArtLayer>; Level: Integer): TList<TArtLayer>;
  var Item: TArtLayer;
  begin
    if List.Count = 0 then Exit(nil);
    if Level > 128 then raise EArtFormat.Create('Group depth limit exceeded');
    if List.Contains(Layer) then begin Depth := Level; Exit(List); end;
    for Item in List do begin
      Result := Find(Item.Children, Level + 1);
      if Result <> nil then Exit;
    end;
    Result := nil;
  end;
begin
  if (Layer = nil) or not FOwnedLayers.Contains(Layer) then
    raise EArtFormat.Create('Layer does not belong to this document');
  Result := Find(Roots, 0);
  if Result = nil then raise EArtFormat.Create('Layer is not in the document tree');
end;

procedure TArtDocument.CheckLayerPlacement(Layer, Parent: TArtLayer);
var Depth, Height: Integer;
  function SubtreeHeight(Item: TArtLayer; Level: Integer): Integer;
  var Child: TArtLayer;
  begin
    if (Item = Parent) then raise EArtFormat.Create('Cannot move a layer into itself or its descendants');
    if Level > 128 then raise EArtFormat.Create('Group depth limit exceeded');
    Result := 0;
    // An empty group still opens one nesting level in PSD validation.
    if Item.Kind = alkGroup then Result := 1;
    for Child in Item.Children do Result := Max(Result, 1 + SubtreeHeight(Child, Level + 1));
  end;
begin
  LayerLocation(Layer, Depth);
  Height := SubtreeHeight(Layer, 0);
  if Parent = nil then Depth := 0
  else begin
    LayerLocation(Parent, Depth);
    if Parent.Kind <> alkGroup then raise EArtFormat.Create('Parent must be a group');
    Inc(Depth);
  end;
  if Depth + Height > 128 then raise EArtFormat.Create('Group depth limit exceeded');
end;

function TArtDocument.MoveLayer(Layer, Parent: TArtLayer; Index: Integer): Boolean;
var Source, Target: TList<TArtLayer>; Depth, OldIndex, Count: Integer;
begin
  CheckLayerPlacement(Layer, Parent);
  Source := LayerLocation(Layer, Depth); OldIndex := Source.IndexOf(Layer);
  if Parent = nil then Target := Roots else Target := Parent.Children;
  Count := Target.Count; if Source = Target then Dec(Count);
  if (Index < 0) or (Index > Count) then raise EArtFormat.Create('Layer index is out of range');
  Result := (Source <> Target) or (OldIndex <> Index);
  if not Result then Exit;
  // Reserve before detaching, so allocation failure leaves the tree intact.
  if Source <> Target then Target.Capacity := Max(Target.Capacity, Target.Count + 1);
  Source.Delete(OldIndex); Target.Insert(Index, Layer);
end;

function TArtDocument.SwapLayers(Layer, Other: TArtLayer): Boolean;
var Left, Right: TList<TArtLayer>; Depth, LeftIndex, RightIndex: Integer;
    LeftParent, RightParent, Item: TArtLayer;
begin
  Left := LayerLocation(Layer, Depth); Right := LayerLocation(Other, Depth);
  Result := Layer <> Other;
  if not Result then Exit;
  LeftParent := nil; RightParent := nil;
  for Item in FOwnedLayers do begin
    if Item.Children = Left then LeftParent := Item;
    if Item.Children = Right then RightParent := Item;
  end;
  // Reject ancestor/descendant swaps and excessive nesting before any mutation.
  CheckLayerPlacement(Layer, RightParent); CheckLayerPlacement(Other, LeftParent);
  LeftIndex := Left.IndexOf(Layer); RightIndex := Right.IndexOf(Other);
  Left[LeftIndex] := Other; Right[RightIndex] := Layer;
end;

procedure TArtDocument.DeleteLayer(Layer: TArtLayer);
var Source, Subtree: TList<TArtLayer>; Seen: TDictionary<TArtLayer, Boolean>; Depth: Integer;
  procedure Collect(Item: TArtLayer; Level: Integer);
  var Child: TArtLayer;
  begin
    if (Level > 128) or (Item = nil) or not FOwnedLayers.Contains(Item) or Seen.ContainsKey(Item) then
      raise EArtFormat.Create('Invalid, repeated or cyclic layer reference');
    Seen.Add(Item, True); Subtree.Add(Item);
    for Child in Item.Children do Collect(Child, Level + 1);
  end;
begin
  Source := LayerLocation(Layer, Depth);
  if (Source = Roots) and (Roots.Count = 1) then
    raise EArtFormat.Create('At least one root layer must remain');
  Subtree := TList<TArtLayer>.Create; Seen := TDictionary<TArtLayer, Boolean>.Create;
  try
    // Collect before detaching, so validation/allocation failure leaves the tree intact.
    Collect(Layer, 0); Source.Remove(Layer);
    for var Item in Subtree do FOwnedLayers.Remove(Item);
  finally Seen.Free; Subtree.Free; end;
end;

function TArtDocument.Clone: TArtDocument;
  procedure CopyTree(List: TList<TArtLayer>; Parent: TArtLayer);
  var L,N: TArtLayer;
  begin
    for L in List do begin
      N := Result.AddLayer(L.Kind,L.Name,L.Bounds,Parent);
      N.Id := L.Id; N.Visible := L.Visible; N.Opacity := L.Opacity;
      N.BlendKey := L.BlendKey; N.Clipping := L.Clipping; N.SectionType := L.SectionType; N.SourceIndex := L.SourceIndex;
      // Pixel arrays are immutable assets: replacements assign a new array.
      N.Pixels := L.Pixels; N.HasMask := L.HasMask; N.MaskBounds := L.MaskBounds;
      N.MaskDefault := L.MaskDefault; N.MaskDisabled := L.MaskDisabled; N.MaskInvert := L.MaskInvert; N.MaskPixels := L.MaskPixels;
      CopyTree(L.Children,N);
    end;
  end;
begin
  Result := TArtDocument.Create;
  try
    Result.SessionId := SessionId; Result.Revision := Revision; Result.Width := Width; Result.Height := Height;
    Result.SourceBytes := SourceBytes; Result.SourceRecordCount := SourceRecordCount;
    Result.MergedPlanes := MergedPlanes; Result.MergedHasTransparency := MergedHasTransparency;
    Result.Unsupported.Assign(Unsupported); CopyTree(Roots,nil);
  except Result.Free; raise; end;
end;

procedure TArtDocument.ValidateStructure(ForRender: Boolean);
var Seen: TDictionary<TArtLayer, Boolean>; Records: Integer;
  procedure Visit(List: TList<TArtLayer>; Depth: Integer);
  var L: TArtLayer;
  begin
    if Depth > 128 then raise EArtFormat.Create('Group depth limit exceeded');
    for L in List do begin
      if (L = nil) or not FOwnedLayers.Contains(L) or Seen.ContainsKey(L) then
        raise EArtFormat.Create('Invalid, repeated or cyclic layer reference');
      Seen.Add(L, True);
      if L.Kind = alkDivider then raise EArtFormat.Create('Divider in editable tree');
      Inc(Records);
      if L.HasMask then begin
        if (L.Kind<>alkImage) and (not ForRender or (L.BlendKey<>'norm')) then
          raise EArtFormat.Create('Only isolated normal group masks can be rendered');
        if (L.MaskDefault<>0) and (L.MaskDefault<>255) then raise EArtFormat.Create('Invalid mask default');
        if Length(L.MaskPixels)<>PixelByteCount(L.MaskBounds.Width,L.MaskBounds.Height,1) then
          raise EArtFormat.Create('Mask pixel buffer size mismatch');
      end else if Length(L.MaskPixels)<>0 then raise EArtFormat.Create('Mask pixels without mask');
      if (L.Clipping <> 0) then raise EArtFormat.Create('Clipping rendering not implemented');
      if L.Kind = alkImage then begin
        if (L.BlendKey <> 'norm') and (not ForRender or (L.BlendKey<>'mul ')) then
          raise EArtFormat.Create('Only normal and multiply image blending can be rendered');
        if L.Children.Count <> 0 then raise EArtFormat.Create('Image layer has children');
        if Length(L.Pixels) <> PixelByteCount(L.Bounds.Width, L.Bounds.Height, 4) then
          raise EArtFormat.Create('Layer pixel buffer size mismatch');
      end else begin
        if (L.BlendKey <> 'norm') and ((L.BlendKey <> 'pass') or (L.Opacity <> 255)) then
          raise EArtFormat.Create('Only normal or full-opacity pass-through groups implemented');
        Inc(Records); Visit(L.Children, Depth + 1);
      end;
      if Records > 32767 then raise EArtFormat.Create('Too many PSD layer records');
    end;
  end;
begin
  if (Width < 1) or (Height < 1) or (Width > 30000) or (Height > 30000) then
    raise EArtFormat.Create('Invalid PSD canvas');
  PixelByteCount(Width, Height, 4);
  if Length(SourceBytes) <> 0 then
    raise EArtFormat.Create('Re-encoding imported PSD is disabled until source-information preservation is implemented');
  if Unsupported.Count <> 0 then raise EArtFormat.Create('Unsupported source information');
  if Roots.Count = 0 then raise EArtFormat.Create('A new PSD requires at least one layer');
  Seen := TDictionary<TArtLayer, Boolean>.Create;
  try
    Records := 0; Visit(Roots, 0);
  finally Seen.Free; end;
end;

procedure TArtDocument.ValidateForNewSave;
begin
  ValidateStructure(False);
end;

function TArtDocument.RenderRGBA(OutputWidth,OutputHeight: Integer): TBytes;
var Output: TBytes; W,H,I: Integer; XMap,YMap: TArray<Integer>; Area: TRect;
  procedure IncludeArea(var Target: TRect; const Added: TRect);
  begin
    if (Added.Right<=Added.Left) or (Added.Bottom<=Added.Top) then Exit;
    if (Target.Right<=Target.Left) or (Target.Bottom<=Target.Top) then Target := Added
    else begin Target.Left := Min(Target.Left,Added.Left); Target.Top := Min(Target.Top,Added.Top);
      Target.Right := Max(Target.Right,Added.Right); Target.Bottom := Max(Target.Bottom,Added.Bottom); end;
  end;
  function SinglePlainImage(List: TList<TArtLayer>; var Count: Integer): Boolean;
  var L: TArtLayer;
  begin
    Result := False;
    for L in List do begin
      if not L.Visible or (L.Opacity=0) then Continue;
      if (L.Opacity<>255) or (L.HasMask and not L.MaskDisabled) then Exit;
      if L.Kind=alkGroup then begin
        if not SinglePlainImage(L.Children,Count) then Exit;
      end else begin
        if L.BlendKey<>'norm' then Exit;
        Inc(Count); if Count>1 then Exit;
      end;
    end;
    Result := True;
  end;
  function MaskCoverage(L: TArtLayer; X,Y: Int64): Double;
  var MX,MY: Int64; Value: Integer;
  begin
    Result := 1;
    if not L.HasMask or L.MaskDisabled then Exit;
    MX := X-L.MaskBounds.Left; MY := Y-L.MaskBounds.Top; Value := L.MaskDefault;
    if (MX>=0) and (MY>=0) and (MX<L.MaskBounds.Width) and (MY<L.MaskBounds.Height) then
      Value := L.MaskPixels[Integer(MY)*L.MaskBounds.Width+Integer(MX)];
    if L.MaskInvert then Value := 255-Value;
    Result := Value/255.0;
  end;
  procedure Draw(List: TList<TArtLayer>; var Target: TBytes; Depth: Integer; out Area: TRect);
  var I, X, Y, P, Q, C,Left,Top,Right,Bottom,Alpha,Inv,ImageCount: Integer; L: TArtLayer;
      SX, SY: Int64; SA, DA, OA, Value: Double; Group: TBytes; ChildArea: TRect; Unmasked: Boolean;
  begin
    Area := Rect(0,0,0,0);
    for I := List.Count - 1 downto 0 do begin
      L := List[I];
      if not L.Visible or (L.Opacity=0) then Continue;
      Unmasked := not L.HasMask or L.MaskDisabled;
      if L.Kind = alkGroup then begin
        ImageCount := 0;
        // An unmodified single normal image has the same straight RGBA when
        // isolated. Its wrapper groups need no intermediate canvas buffers.
        if (L.BlendKey='pass') or ((L.Opacity=255) and Unmasked and SinglePlainImage(L.Children,ImageCount)) then begin
          Draw(L.Children,Target,Depth+1,ChildArea); IncludeArea(Area,ChildArea);
        end
        else begin
          if Int64(Depth+1)*Length(Target)>ART_MAX_BYTES then raise EArtFormat.Create('Group composite memory limit');
          SetLength(Group,Length(Target)); if Length(Group)>0 then FillChar(Group[0],Length(Group),0);
          Draw(L.Children,Group,Depth+1,ChildArea);
          // A normal group affects only its visible children. Transparent canvas
          // pixels need no source-over calculation, even for nested groups.
          for Y := ChildArea.Top to ChildArea.Bottom-1 do
            for X := ChildArea.Left to ChildArea.Right-1 do begin
              P := (Y*W+X)*4;
              if Group[P+3]=0 then Continue;
              if (L.Opacity=255) and Unmasked then begin
                if (Group[P+3]=255) or (Target[P+3]=0) then begin
                  PCardinal(@Target[P])^ := PCardinal(@Group[P])^; Continue;
                end;
                if Target[P+3]=255 then begin
                  Alpha := Group[P+3]; Inv := 255-Alpha;
                  for C := 0 to 2 do Target[P+C] := (Group[P+C]*Alpha+Target[P+C]*Inv+127) div 255;
                  Continue;
                end;
              end;
              SA := Group[P+3]/255.0*L.Opacity/255.0*MaskCoverage(L,XMap[X],YMap[Y]);
              if SA<=0 then Continue;
              DA := Target[P+3]/255.0; OA := SA+DA*(1-SA);
              for C := 0 to 2 do Target[P+C] := EnsureRange(Round((Group[P+C]*SA+Target[P+C]*DA*(1-SA))/OA),0,255);
              Target[P+3] := EnsureRange(Round(OA*255),0,255);
            end;
          IncludeArea(Area,ChildArea);
          Group := nil;
        end;
        Continue;
      end;
      Left := (Int64(EnsureRange(L.Bounds.Left,0,Width))*W+Width-1) div Width;
      Right := (Int64(EnsureRange(L.Bounds.Right,0,Width))*W+Width-1) div Width;
      Top := (Int64(EnsureRange(L.Bounds.Top,0,Height))*H+Height-1) div Height;
      Bottom := (Int64(EnsureRange(L.Bounds.Bottom,0,Height))*H+Height-1) div Height;
      IncludeArea(Area,Rect(Left,Top,Right,Bottom));
      for Y := Top to Bottom-1 do begin
        SY := YMap[Y];
        for X := Left to Right-1 do begin
          SX := XMap[X];
          P := ((Integer(SY)-L.Bounds.Top)*L.Bounds.Width+Integer(SX)-L.Bounds.Left)*4;
          Q := (Y*W+X)*4;
          if L.Pixels[P+3]=0 then Continue;
          if (L.Opacity=255) and Unmasked and (L.BlendKey='norm') then begin
            if (L.Pixels[P+3]=255) or (Target[Q+3]=0) then begin
              PCardinal(@Target[Q])^ := PCardinal(@L.Pixels[P])^; Continue;
            end;
            if Target[Q+3]=255 then begin
              Alpha := L.Pixels[P+3]; Inv := 255-Alpha;
              for C := 0 to 2 do Target[Q+C] := (L.Pixels[P+C]*Alpha+Target[Q+C]*Inv+127) div 255;
              Continue;
            end;
          end;
          SA := (L.Pixels[P+3] / 255.0) * (L.Opacity / 255.0) * MaskCoverage(L,SX,SY);
          if SA<=0 then Continue;
          DA := Target[Q+3] / 255.0;
          OA := SA + DA * (1 - SA);
          if OA <= 0 then Continue;
          for C := 0 to 2 do begin
            Value := L.Pixels[P+C];
            // W3Cのsource-over式。透明な背景部分では元色を残し、重なる部分だけ乗算。
            if L.BlendKey='mul ' then Value := Value*(1-DA)+Value*Target[Q+C]/255.0*DA;
            Value := (Value * SA + Target[Q+C] * DA * (1-SA)) / OA;
            Target[Q+C] := Byte(EnsureRange(Round(Value), 0, 255));
          end;
          Target[Q+3] := Byte(EnsureRange(Round(OA * 255), 0, 255));
        end;
      end;
    end;
  end;
begin
  ValidateStructure(True);
  W := OutputWidth; H := OutputHeight;
  if W=0 then W := Width; if H=0 then H := Height;
  if (W<1) or (H<1) or (W>Width) or (H>Height) then raise EArtFormat.Create('Invalid preview dimensions');
  SetLength(XMap,W); for I := 0 to W-1 do XMap[I] := Int64(I)*Width div W;
  SetLength(YMap,H); for I := 0 to H-1 do YMap[I] := Int64(I)*Height div H;
  SetLength(Output, PixelByteCount(W,H,4));
  Draw(Roots,Output,0,Area);
  Result := Output;
end;

end.
