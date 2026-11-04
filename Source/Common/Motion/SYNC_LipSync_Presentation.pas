unit SYNC_LipSync_Presentation;

// 登場・退場演出の種類と合成用の透明度・描画矩形を決める。

interface

uses System.Types;

type
  TLipSyncPresentation = (lpNone, lpFadeIn, lpFadeOut,
    lpSlideInLeft, lpSlideInRight, lpSlideInTop, lpSlideInBottom,
    lpSlideOutLeft, lpSlideOutRight, lpSlideOutTop, lpSlideOutBottom,
    lpZoomIn, lpZoomOut);

  TLipSyncPresentationFrame = record
    Cue: TLipSyncPresentation;
    Progress: Double;
    Opacity: Byte;
    // Frameは出力領域、BoundsはPSDの保存済み配置を投影した矩形。
    // 試写と出力で同じ位置を求め、保存済み配置は変更しない。
    function AdjustBounds(const Frame, Bounds: TRect): TRect;
  end;

function LipSyncPresentationKey(Value: TLipSyncPresentation): string;
function LipSyncPresentationCaption(Value: TLipSyncPresentation): string;
function LipSyncPresentationIsEntrance(Value: TLipSyncPresentation): Boolean;
// Progressは区間内の経過率。未設定の場合は等倍・不透明のまま返す。
function LipSyncPresentationFrame(Cue: TLipSyncPresentation; Progress: Double): TLipSyncPresentationFrame;

implementation

uses System.Math;

function LipSyncPresentationKey(Value: TLipSyncPresentation): string;
const Keys: array[TLipSyncPresentation] of string =
  ('none','fadeIn','fadeOut','slideInLeft','slideInRight','slideInTop','slideInBottom',
   'slideOutLeft','slideOutRight','slideOutTop','slideOutBottom','zoomIn','zoomOut');
begin
  Result := Keys[Value];
end;

function LipSyncPresentationCaption(Value: TLipSyncPresentation): string;
const Captions: array[TLipSyncPresentation] of string =
  ('演出（未設定）','フェードイン','フェードアウト',
   '左からスライドイン','右からスライドイン','上からスライドイン','下からスライドイン',
   '左へスライドアウト','右へスライドアウト','上へスライドアウト','下へスライドアウト',
   '拡大して登場','縮小して退場');
begin
  Result := Captions[Value];
end;

function LipSyncPresentationIsEntrance(Value: TLipSyncPresentation): Boolean;
begin
  Result := Value in [lpFadeIn,lpSlideInLeft,lpSlideInRight,lpSlideInTop,lpSlideInBottom,lpZoomIn];
end;

function LipSyncPresentationFrame(Cue: TLipSyncPresentation; Progress: Double): TLipSyncPresentationFrame;
begin
  Result.Cue := Cue;
  Result.Progress := EnsureRange(Progress,0.0,1.0);
  case Cue of
    lpFadeIn, lpZoomIn: Result.Opacity := Round(255*Result.Progress);
    lpFadeOut, lpZoomOut: Result.Opacity := Round(255*(1-Result.Progress));
  else
    Result.Opacity := 255;
    if ((Cue in [lpSlideInLeft,lpSlideInRight,lpSlideInTop,lpSlideInBottom]) and
      (Result.Progress=0)) or
      ((Cue in [lpSlideOutLeft,lpSlideOutRight,lpSlideOutTop,lpSlideOutBottom]) and
      (Result.Progress=1)) then Result.Opacity := 0;
  end;
end;

function TLipSyncPresentationFrame.AdjustBounds(const Frame, Bounds: TRect): TRect;
var
  Amount, Scale, CX, CY, W, H: Double;
  X,Y: Integer;
begin
  Result := Bounds;
  if Bounds.IsEmpty or (Cue in [lpNone,lpFadeIn,lpFadeOut]) then Exit;
  Amount := Progress*Progress*(3-2*Progress);
  if LipSyncPresentationIsEntrance(Cue) then Amount := 1-Amount;
  X := 0;
  Y := 0;
  case Cue of
    lpSlideInLeft, lpSlideOutLeft: X := Round(Min(0,Frame.Left-Bounds.Right)*Amount);
    lpSlideInRight, lpSlideOutRight: X := Round(Max(0,Frame.Right-Bounds.Left)*Amount);
    lpSlideInTop, lpSlideOutTop: Y := Round(Min(0,Frame.Top-Bounds.Bottom)*Amount);
    lpSlideInBottom, lpSlideOutBottom: Y := Round(Max(0,Frame.Bottom-Bounds.Top)*Amount);
    lpZoomIn, lpZoomOut:
      begin
        Scale := 1-0.65*Amount;
        CX := (Bounds.Left+Bounds.Right)/2;
        CY := (Bounds.Top+Bounds.Bottom)/2;
        W := Max(1,Bounds.Width*Scale);
        H := Max(1,Bounds.Height*Scale);
        Result := Rect(Round(CX-W/2),Round(CY-H/2),Round(CX+W/2),Round(CY+H/2));
        Result.Right := Max(Result.Left+1,Result.Right);
        Result.Bottom := Max(Result.Top+1,Result.Bottom);
      end;
  end;
  Result.Offset(X,Y);
end;

end.

