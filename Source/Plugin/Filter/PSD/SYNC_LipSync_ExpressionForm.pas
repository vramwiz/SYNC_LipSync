unit SYNC_LipSync_ExpressionForm;

// 表情区間の表示差分をPSDツリーで編集する。閉じたときに区間へ反映する。

interface

uses
  System.JSON, SYNC_LipSync_Project;

// キャラクターと区間を借用し、閉じると区間所有の表示差分だけを更新する。
procedure EditLipSyncExpression(Character: TLipSyncCharacter; Effect: TLipSyncEffect);

implementation

uses
  Winapi.Windows, Winapi.CommCtrl, System.Classes, System.SysUtils, System.Types,
  System.Generics.Collections, Vcl.Forms, Vcl.Controls, Vcl.ComCtrls, Vcl.ExtCtrls,
  Vcl.Graphics, Vcl.StdCtrls, Winapi.UxTheme,
  SYNC_MusicStudio_PsdLayers, SYNC_MusicStudio_PsdLayerConfig,
  SYNC_MusicStudio_HostBackground, SYNC_MusicStudio_DarkTheme;

type
  TExpressionPreview = class(TPaintBox)
  public
    constructor Create(AOwner: TComponent); override;
  end;

  TExpressionForm = class(TForm)
  private
    FCharacter: TLipSyncCharacter;
    FTree: TTreeView;
    FPreview: TPaintBox;
    FImage, FBuffer: Vcl.Graphics.TBitmap;
    FBase: TArray<Boolean>;
    FChecked: TArray<Boolean>;
    procedure CloseClick(Sender: TObject);
    procedure ChangeChecks;
    procedure TreeClick(Sender: TObject);
    procedure TreeKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure PaintPreview(Sender: TObject);
    function ReadCheck(Node: TTreeNode): Boolean;
    procedure SetCheck(Node: TTreeNode; Value: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure LoadExpression(Character: TLipSyncCharacter; const Overrides: TJSONObject);
    function Capture: TJSONObject;
  end;

constructor TExpressionPreview.Create(AOwner: TComponent);
begin
  inherited;
  ControlStyle := ControlStyle + [csOpaque];
end;

constructor TExpressionForm.Create(AOwner: TComponent);
var
  Footer: TPanel;
  CloseButton: TButton;
begin
  inherited CreateNew(AOwner);
  Caption := '表情の編集';
  Position := poScreenCenter;
  ClientWidth := 770;
  ClientHeight := 520;
  Font.Name := 'Yu Gothic UI';
  Font.Height := -13;
  ApplySyncMusicStudioDarkForm(Self);
  FImage := Vcl.Graphics.TBitmap.Create;
  FBuffer := Vcl.Graphics.TBitmap.Create;

  Footer := TPanel.Create(Self);
  Footer.Parent := Self;
  Footer.Align := alBottom;
  Footer.Height := 39;
  ApplySyncMusicStudioDarkPanel(Footer);
  CloseButton := TButton.Create(Self);
  CloseButton.Parent := Footer;
  CloseButton.SetBounds(8,6,85,26);
  CloseButton.Caption := '閉じる';
  CloseButton.Cancel := True;
  CloseButton.OnClick := CloseClick;
  ApplySyncMusicStudioDarkButton(CloseButton);

  FTree := TTreeView.Create(Self);
  FTree.Parent := Self;
  FTree.Align := alLeft;
  FTree.Width := 320;
  FTree.ReadOnly := True;
  FTree.HideSelection := False;
  FTree.Color := SYNC_MUSIC_STUDIO_DARK_CONTROL_COLOR;
  FTree.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
  FTree.StyleElements := FTree.StyleElements - [seClient];
  SetWindowLongPtr(FTree.Handle,GWL_STYLE,GetWindowLongPtr(FTree.Handle,GWL_STYLE) or TVS_CHECKBOXES);
  SetWindowTheme(FTree.Handle,'DarkMode_Explorer',nil);
  FTree.OnClick := TreeClick;
  FTree.OnKeyUp := TreeKey;

  FPreview := TExpressionPreview.Create(Self);
  FPreview.Parent := Self;
  FPreview.Align := alClient;
  FPreview.OnPaint := PaintPreview;
end;

destructor TExpressionForm.Destroy;
begin
  FBuffer.Free;
  FImage.Free;
  inherited;
end;

procedure TExpressionForm.CloseClick(Sender: TObject);
begin
  Close;
end;

function TExpressionForm.ReadCheck(Node: TTreeNode): Boolean;
var Item: TTVItem;
begin
  Item := Default(TTVItem);
  Item.mask := TVIF_STATE;
  Item.hItem := Node.ItemId;
  Item.stateMask := TVIS_STATEIMAGEMASK;
  SendMessage(FTree.Handle,TVM_GETITEM,0,LPARAM(@Item));
  Result := (Item.state and TVIS_STATEIMAGEMASK) = $2000;
end;

procedure TExpressionForm.SetCheck(Node: TTreeNode; Value: Boolean);
var Item: TTVItem;
begin
  Item := Default(TTVItem);
  Item.mask := TVIF_STATE;
  Item.hItem := Node.ItemId;
  Item.stateMask := TVIS_STATEIMAGEMASK;
  if Value then Item.state := $2000 else Item.state := $1000;
  SendMessage(FTree.Handle,TVM_SETITEM,0,LPARAM(@Item));
end;

procedure TExpressionForm.LoadExpression(Character: TLipSyncCharacter; const Overrides: TJSONObject);
var
  Nodes: TDictionary<string,TTreeNode>;
  Config, Visibility: TJSONObject;
  Layers: TArray<TMusicStudioLayerInfo>;
  I: Integer;
  Parent, Node: TTreeNode;
  Value: TJSONValue;
begin
  FCharacter := Character;
  Layers := Character.Scene.Document.Layers;
  SetLength(FBase,Length(Layers));
  SetLength(FChecked,Length(Layers));
  Config := ParseMusicStudioPsdConfig(Character.Settings);
  Nodes := TDictionary<string,TTreeNode>.Create;
  FTree.Items.BeginUpdate;
  try
    Visibility := MusicStudioPsdConfigObject(Config,'visibility');
    for I := 0 to High(Layers) do
    begin
      if not Nodes.TryGetValue(Layers[I].ParentKey,Parent) then Parent := nil;
      Node := FTree.Items.AddChildObject(Parent,Layers[I].Name,Pointer(NativeInt(I+1)));
      Nodes.Add(Layers[I].Key,Node);
      FBase[I] := Layers[I].Visible;
      Value := Visibility.GetValue(Layers[I].Key);
      if Value is TJSONBool then FBase[I] := TJSONBool(Value).AsBoolean;
      FChecked[I] := FBase[I];
      Value := Overrides.GetValue(Layers[I].Key);
      if Value is TJSONBool then FChecked[I] := TJSONBool(Value).AsBoolean;
      SetCheck(Node,FChecked[I]);
    end;
    FTree.FullExpand;
  finally
    FTree.Items.EndUpdate;
    Nodes.Free;
    Config.Free;
  end;
end;

procedure TExpressionForm.ChangeChecks;
var
  Node: TTreeNode;
  Changed: TJSONObject;
  Pair: TJSONPair;
  Index: Integer;
  Checked: Boolean;
begin
  if not Assigned(FCharacter) then Exit;
  Changed := TJSONObject.Create;
  try
    Node := FTree.Items.GetFirstNode;
    while Node <> nil do
    begin
      Index := NativeInt(Node.Data)-1;
      Checked := ReadCheck(Node);
      if Checked and not FChecked[Index] then
        FCharacter.Scene.Document.SelectLayerOverride(Changed,FCharacter.Scene.Document.Layers[Index].Key);
      FChecked[Index] := Checked;
      Node := Node.GetNext;
    end;
    for Pair in Changed do
    begin
      Index := FCharacter.Scene.Document.LayerIndex(Pair.JsonString.Value);
      if Index < 0 then Continue;
      FChecked[Index] := TJSONBool(Pair.JsonValue).AsBoolean;
      SetCheck(FTree.Items[Index],FChecked[Index]);
    end;
  finally
    Changed.Free;
  end;
end;

procedure TExpressionForm.TreeClick(Sender: TObject);
begin
  FPreview.Invalidate;
end;

procedure TExpressionForm.TreeKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  FPreview.Invalidate;
end;

function TExpressionForm.Capture: TJSONObject;
var
  I: Integer;
  Layers: TArray<TMusicStudioLayerInfo>;
begin
  ChangeChecks;
  Result := TJSONObject.Create;
  Layers := FCharacter.Scene.Document.Layers;
  for I := 0 to High(FChecked) do
    if FChecked[I] <> FBase[I] then
      MusicStudioSetJsonBoolean(Result,Layers[I].Key,FChecked[I]);
end;

procedure TExpressionForm.PaintPreview(Sender: TObject);
var
  Overrides: TJSONObject;
  Bounds: TRect;
  Blend: TBlendFunction;
begin
  if not Assigned(FCharacter) or (FPreview.Width<=0) or (FPreview.Height<=0) then Exit;
  FBuffer.SetSize(FPreview.Width,FPreview.Height);
  FBuffer.Canvas.Brush.Color := SYNC_MUSIC_STUDIO_DARK_BACKGROUND_COLOR;
  FBuffer.Canvas.FillRect(FPreview.ClientRect);
  Overrides := Capture;
  try
    if FCharacter.Scene.Render(FImage,0,0,'',3,Overrides) then
    begin
      Bounds := MusicStudioFitFrameRect(FPreview.ClientRect,FImage.Width,FImage.Height);
      Blend.BlendOp := AC_SRC_OVER;
      Blend.BlendFlags := 0;
      Blend.SourceConstantAlpha := 255;
      Blend.AlphaFormat := AC_SRC_ALPHA;
      Winapi.Windows.AlphaBlend(FBuffer.Canvas.Handle,Bounds.Left,Bounds.Top,Bounds.Width,Bounds.Height,
        FImage.Canvas.Handle,0,0,FImage.Width,FImage.Height,Blend);
    end;
  finally
    Overrides.Free;
  end;
  FPreview.Canvas.Draw(0,0,FBuffer);
end;

procedure EditLipSyncExpression(Character: TLipSyncCharacter; Effect: TLipSyncEffect);
var
  Form: TExpressionForm;
  Updated: TJSONObject;
begin
  Form := TExpressionForm.Create(nil);
  try
    Form.LoadExpression(Character,Effect.Visibility);
    Form.ShowModal;
    Updated := Form.Capture;
    Effect.Visibility.Free;
    Effect.Visibility := Updated;
  finally
    Form.Free;
  end;
end;

end.

