unit SYNC_LipSync_PreviewViewport;

// プレビューだけの表示倍率と平行移動。PSDの作品内配置には反映しない。

interface

uses System.Types, Vcl.Graphics, SYNC_MusicStudio_PsdTransform;

type
  TLipSyncPreviewViewport = record
  private
    FZoom: Double;
    FPan: TPointF;
    function Zoom: Double;
  public
    // Fitは等倍時の表示矩形。保存用の座標は変えず、画面上の矩形を返す。
    function Frame(const Fit: TRect): TRect;
    procedure ZoomAt(const Fit: TRect; const Cursor: TPoint; Delta: Integer);
    procedure PanBy(DX, DY: Integer);
    procedure Reset;
  end;

function LipSyncGripAt(const Bounds: TRect; const P: TPoint; GripSize: Integer): Integer;
procedure DrawLipSyncPlacement(Canvas: TCanvas; const Bounds: TRect; GripSize: Integer);
// マウスの移動量から配置候補を求める。OriginalとPSD素材は変更しない。
function LipSyncDragPlacement(const Original: TMusicStudioPsdTransform;
  const Bounds, Frame: TRect; OutputWidth, OutputHeight, Grip, DX, DY: Integer): TMusicStudioPsdTransform;

implementation

uses System.Math, System.UITypes;

function TLipSyncPreviewViewport.Zoom: Double;
begin
  Result := FZoom;
  if Result = 0 then Result := 1;
end;

function TLipSyncPreviewViewport.Frame(const Fit: TRect): TRect;
var
  X, Y, W, H: Double;
begin
  if Fit.IsEmpty then Exit(Fit);
  X := (Fit.Left + Fit.Right) / 2 + FPan.X;
  Y := (Fit.Top + Fit.Bottom) / 2 + FPan.Y;
  W := Max(1, Fit.Width * Zoom);
  H := Max(1, Fit.Height * Zoom);
  Result := Rect(Round(X - W / 2), Round(Y - H / 2),
    Round(X + W / 2), Round(Y + H / 2));
end;

procedure TLipSyncPreviewViewport.ZoomAt(const Fit: TRect; const Cursor: TPoint; Delta: Integer);
var
  Previous, Ratio, X, Y: Double;
begin
  if Fit.IsEmpty or (Delta = 0) then Exit;
  Previous := Zoom;
  FZoom := EnsureRange(Previous * Power(1.2, Delta / 120), 0.1, 16.0);
  Ratio := FZoom / Previous;
  X := Cursor.X - (Fit.Left + Fit.Right) / 2;
  Y := Cursor.Y - (Fit.Top + Fit.Bottom) / 2;
  FPan.X := X - (X - FPan.X) * Ratio;
  FPan.Y := Y - (Y - FPan.Y) * Ratio;
end;

procedure TLipSyncPreviewViewport.PanBy(DX, DY: Integer);
begin
  FPan.X := FPan.X + DX;
  FPan.Y := FPan.Y + DY;
end;

procedure TLipSyncPreviewViewport.Reset;
begin
  FZoom := 1;
  FPan := PointF(0, 0);
end;

function GripRect(const Bounds: TRect; Index, Size: Integer): TRect;
var
  P: TPoint;
begin
  P := Bounds.TopLeft;
  if Index in [2,4] then P.X := Bounds.Right;
  if Index in [3,4] then P.Y := Bounds.Bottom;
  Result := Rect(P.X-Size,P.Y-Size,P.X+Size+1,P.Y+Size+1);
end;

function LipSyncGripAt(const Bounds: TRect; const P: TPoint; GripSize: Integer): Integer;
var I: Integer;
begin
  Result := 0;
  if Bounds.IsEmpty then Exit;
  for I := 1 to 4 do
    if GripRect(Bounds,I,GripSize).Contains(P) then Exit(I);
  if Bounds.Contains(P) then Result := 5;
end;

procedure DrawLipSyncPlacement(Canvas: TCanvas; const Bounds: TRect; GripSize: Integer);
var I: Integer;
begin
  if Bounds.IsEmpty then Exit;
  Canvas.Brush.Style := bsClear;
  Canvas.Pen.Color := clWhite;
  Canvas.Rectangle(Bounds);
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := clWhite;
  Canvas.Pen.Color := $004A4A4A;
  for I := 1 to 4 do Canvas.Rectangle(GripRect(Bounds,I,GripSize));
end;

function LipSyncDragPlacement(const Original: TMusicStudioPsdTransform;
  const Bounds, Frame: TRect; OutputWidth, OutputHeight, Grip, DX, DY: Integer): TMusicStudioPsdTransform;
var
  OffsetX, OffsetY, W, H, Factor: Double;
  SX, SY: Integer;
begin
  Result := Original;
  if Bounds.IsEmpty or Frame.IsEmpty or (Grip = 0) then Exit;
  OffsetX := DX;
  OffsetY := DY;
  if Grip <> 5 then
  begin
    W := Bounds.Width;
    H := Bounds.Height;
    SX := 1;
    SY := 1;
    if Grip in [1,3] then SX := -1;
    if Grip in [1,2] then SY := -1;
    // 対角を固定し、対角方向への移動量から縦横比を維持する。
    Factor := 1+(DX*SX*W+DY*SY*H)/(W*W+H*H);
    Result.Scale := EnsureRange(Original.Scale*Factor,0.001,256.0);
    Factor := Result.Scale/Original.Scale;
    OffsetX := SX*W*(Factor-1)/2;
    OffsetY := SY*H*(Factor-1)/2;
  end;
  Result.StageX := EnsureRange(Original.StageX+OffsetX*OutputWidth/Frame.Width,-30720.0,30720.0);
  Result.StageY := EnsureRange(Original.StageY+OffsetY*OutputHeight/Frame.Height,-17280.0,17280.0);
end;

end.

