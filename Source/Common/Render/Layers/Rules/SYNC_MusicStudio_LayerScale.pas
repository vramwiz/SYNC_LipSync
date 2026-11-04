unit SYNC_MusicStudio_LayerScale;
// 合成専用cloneの部位を中心基準で縮小。PSD原本・解析表・他のレイヤーは変更しない。
interface
uses SYNC_MusicStudio_ArtDocument;
procedure ScaleMusicStudioArtLayer(Layer: TArtLayer; Scale: Double);
implementation
uses System.SysUtils, System.Math, System.Types;
procedure ScaleMusicStudioArtLayer(Layer: TArtLayer; Scale: Double);
var Area: TRect; HasArea: Boolean; CX,CY: Double;
  procedure Collect(L: TArtLayer);
  var Child: TArtLayer; R: TRect;
  begin
    if not L.Visible then Exit;
    if (L.Kind=alkImage) and (L.Bounds.Width>0) and (L.Bounds.Height>0) then begin
      R := Rect(L.Bounds.Left,L.Bounds.Top,L.Bounds.Right,L.Bounds.Bottom);
      if HasArea then UnionRect(Area,Area,R) else begin Area := R; HasArea := True; end;
    end;
    for Child in L.Children do Collect(Child);
  end;
  procedure Resample(var Bounds: TArtBounds; var Bytes: TBytes; Channels: Integer);
  var Old: TArtBounds; Scaled: TBytes; X,Y,W,H,SX,SY: Integer;
  begin
    Old := Bounds; if (Old.Width<1) or (Old.Height<1) then Exit;
    W := Max(1,Round(Old.Width*Scale)); H := Max(1,Round(Old.Height*Scale));
    Bounds := TArtBounds.Create(Round(CX+(Old.Left-CX)*Scale),Round(CY+(Old.Top-CY)*Scale),0,0);
    Bounds.Right := Bounds.Left+W; Bounds.Bottom := Bounds.Top+H;
    if Length(Bytes)=0 then Exit;
    if Length(Bytes)<>PixelByteCount(Old.Width,Old.Height,Channels) then raise EArtFormat.Create('部位の画素数が不正です。');
    SetLength(Scaled,PixelByteCount(W,H,Channels));
    for Y := 0 to H-1 do for X := 0 to W-1 do begin
      SX := Int64(X)*Old.Width div W; SY := Int64(Y)*Old.Height div H;
      Move(Bytes[(SY*Old.Width+SX)*Channels],Scaled[(Y*W+X)*Channels],Channels);
    end;
    Bytes := Scaled;
  end;
  procedure Apply(L: TArtLayer);
  var Child: TArtLayer;
  begin
    if L.Kind=alkImage then Resample(L.Bounds,L.Pixels,4);
    if L.HasMask then Resample(L.MaskBounds,L.MaskPixels,1);
    for Child in L.Children do Apply(Child);
  end;
begin
  if (Layer=nil) or (Scale=1) then Exit;
  if IsNan(Scale) or IsInfinite(Scale) or (Scale<0.5) or (Scale>1) then raise EArgumentException.Create('口の倍率が不正です。');
  HasArea := False; Collect(Layer); if not HasArea then Exit;
  CX := (Area.Left+Area.Right)/2; CY := (Area.Top+Area.Bottom)/2; Apply(Layer);
end;
end.
