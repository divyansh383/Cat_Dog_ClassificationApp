import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tflite_flutter/tflite_flutter.dart' as tfl;
import 'package:image/image.dart' as imglib;
import 'package:flutter/painting.dart';
import 'package:camera_app/main.dart';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';


void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key}) : super(key: key);

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  File? _image;
  // List? _result;
  List<List<double>>? _result;
  bool _imageSelected = false;
  bool _loading=false;
  final _imagePicker=ImagePicker();
  //---------------------------
  late tfl.Interpreter _interpreter;
  late List inputShape;
  late List outputShape;
  late tfl.TensorType inputType;
  late tfl.TensorType outputType;

  //-image specs---------------------------
  double x=0;
  late double y=0;
  late double h=0;
  late double w=0;
  late double cls=0;
  late double conf=0;
  //--camera----------------------------------
  CameraImage? cameraImages;
  CameraController? cameraController;
  bool _batchPredictionsComplete = false;
  bool _loadingPredictions=false;
  //----batch detections---------------------------------------
  List<File> batch=[];
  List<List<List<double>>> _batchResults=[];
  //-------------------------------------
  @override
  Future getImage(ImageSource source) async {
    final image = await ImagePicker().pickImage(source: source);
    if (image == null) {
      return;
    }
    final imageTemporary = File(image.path);
    setState(() {
      _image = imageTemporary;
      _imageSelected = false;
      _result = null;
    });
    classifyImage(_image);
  }

  Future<List<File>> selectImageBatch() async {
    final List<File> selectedImages = [];
    try{
       final List<XFile> pickedImages=await ImagePicker().pickMultiImage();
       if(pickedImages !=null && pickedImages.isNotEmpty){
         for (var pickedImage in pickedImages) {
           selectedImages.add(File(pickedImage.path));
         }
       }
       print("files selected");
    } catch(e){
      print("Error");
    }
    classifyBatch(selectedImages);
    return selectedImages;
  }
  //----for image---------------
  Future classifyImage(File? image) async {
    if(image==null){return;}
    final imageBytes = await image.readAsBytes();

    var inputTensor = preProcessImage(imageBytes);
    var outputTensor = List.filled(1 * 10647 * 6, 0.0).reshape([1, 10647, 6]);

    _interpreter.run(inputTensor, outputTensor);
    List<List<double>> detections = postProcess(outputTensor);
    print("------output detection best-----------${detections.length}");

    setState(() {
      if(detections.isEmpty){conf=0;}else{conf=detections[0][4];}
      _loading=false;
      _result=detections;
    });
  }
  //-----------for batch images---------------------------------
  Future classifyBatch(List<File> batchImages) async {
    _loadingPredictions = true;
    _batchPredictionsComplete = false;

    List<List<List<double>>> batchDetections=[];
    for(var imageFile in batchImages){
      final imageBytes=await imageFile.readAsBytes();
      var inputTensor=preProcessImage(imageBytes);
      var outputTensor=List.filled(1 * 10647 * 6, 0.0).reshape([1, 10647, 6]);

      _interpreter.run(inputTensor, outputTensor);
      List<List<double>> detections = postProcess(outputTensor);
      batchDetections.add(detections);
    }
    //printing
    for(List<List<double>> pred in batchDetections){
      print("---------$pred");
    }
    setState((){
      _batchResults=batchDetections;
      _loadingPredictions = false;
      _batchPredictionsComplete = true;
    });
  }

  //--------for video-----------------------------------------------------------------------
  void classifyVideo(CameraImage image) async {
    print("camera open");
    //preprocessing video-----------------------------
    List<double> pixels=[];
    for(var plane in image.planes){
      pixels.addAll(plane.bytes.map((byte)=>byte.toDouble()));
    }
    List<List<List<List<double>>>> inputTensor=[
      List.generate(416, (row){
        return List.generate(416,(col){
          double r=pixels[row*416+col];
          double g=pixels[416 * 416 + row * 416 + col];
          double b=pixels[2 * 416 * 416 + row * 416 + col];
          return [r/255.0,g/255.0,b/255.0];
        });
      })
    ];

    var outputTensor = List.filled(1 * 10647 * 6, 0.0).reshape([1, 10647, 6]);
    //-----------------------------------------------------
    _interpreter.run(inputTensor, outputTensor);
    List<List<double>> detections = postProcess(outputTensor);
    print("------output detection best video-----------$detections");

    setState(() {
      if(detections.isNotEmpty){
         conf=1;
        _loading=false;
        _result=detections;
      }
    });
  }
  //-------------------------------------------------------------------------------------------------

//-------------------------------image processing---------------------------------------------------
  List<List<double>> postProcess(List<dynamic> outputTensor){
      double maxConfidence =0.3;
      List<List<double>> detections=[];
      for(int i=0;i<outputTensor[0].length;i++){
        List<dynamic> prediction=outputTensor[0][i];
          double x = prediction[0];
          double y = prediction[1];
          double w = prediction[2];
          double h = prediction[3];
          double conf = prediction[4];

          if(conf>maxConfidence){
              detections.add([x,y,w,h,conf,prediction[5]]);
          }
          if(detections.length>=5){
            break;
          }
      }
      return detections;
  }

  List<List<List<List<double>>>> preProcessImage(Uint8List imageBytes) {
    imglib.Image img = imglib.decodeImage(imageBytes)!;
    imglib.Image resizedImage = imglib.copyResize(img, width: 416, height: 416);

    List<List<List<List<double>>>> inputValues = List.generate(1, (batchIndex) {
      List<List<List<double>>> batch = [];
      for (int row = 0; row < 416; row++) {
        List<List<double>> rowValues = [];
        for (int col = 0; col < 416; col++) {
          List<double> pixelValues = [];

          int pixel = resizedImage.getPixel(col, row);
          double r = imglib.getRed(pixel)/255.0;
          double g = imglib.getGreen(pixel)/255.0;
          double b = imglib.getBlue(pixel)/255.0;

          pixelValues.add(r);
          pixelValues.add(g);
          pixelValues.add(b);

          rowValues.add(pixelValues);
        }
        batch.add(rowValues);
      }
      return batch;
    });

    return inputValues;
  }

//---------------------------------------------------------------------------------------------------
Future<void> saveFiles(List<List<List<double>>> batchResults) async {

      final excel = Excel.createExcel();
      final sheet = excel['BatchResults'];

      sheet.appendRow(['Image','X','Y','Width','Height','Confidence','Class']);

      for(int imgIndex=0;imgIndex<_batchResults.length;imgIndex++){
        for(var detection in batchResults[imgIndex]){
          sheet.appendRow([imgIndex+1,...detection]);
        }
      }

      final dir=await getApplicationDocumentsDirectory();
      //final desktopDir = Directory('${Platform.environment['USERPROFILE']}\\Desktop');
      final filePath = '${dir.path}/batch_results.xlsx';
      final excelBytes = await excel.encode();

      if (excelBytes != null) {
        final file = File(filePath);
        await file.writeAsBytes(excelBytes);
        print('Batch results saved to $filePath');
      } else {
        print('Error: Excel encoding failed.');
      }
}
//-------------------------------------------------------------
  // Input shape: [1, 416, 416, 3]
  // Output shape: [1, 10647, 6]

  loadCamera(){
    cameraController=CameraController(cameras![0],ResolutionPreset.medium);
    cameraController!.initialize().then((value){
      if(!mounted){
        return;
      }else{
        setState(() {
          cameraController!.startImageStream((imageStream) {
            cameraImages=imageStream;
            //classifyVideo(imageStream);
          });
        });
      }
    });
  }

  Future<void> loadModel() async {
    _interpreter = await tfl.Interpreter.fromAsset("assets/best-fp16.tflite");
    inputShape = _interpreter.getInputTensor(0).shape;
    outputShape = _interpreter.getOutputTensor(0).shape;
    print('--------------------------Input shape: $inputShape');
    print('--------------------------Output shape: $outputShape');
    inputType = _interpreter.getInputTensor(0).type;
    outputType = _interpreter.getOutputTensor(0).type;
    print('--------------------------Input type: $inputType');
    print('--------------------------Output type: $outputType');

  }

  void initState(){
    super.initState();
    _loading=true;
    loadModel().then((value){
      setState(() {
        _loading=false;
      });
    });
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bottle Detector'),
      ),
      body: Center(
        child: Column(
          children: [
            (_loadingPredictions)?
              const CircularProgressIndicator()
            :(_batchResults.isNotEmpty && _image==null) ?

                  ElevatedButton(
                    onPressed: () {
                      saveFiles(_batchResults);
                    },
                    child: const Text('Download Results')
              )
                : _image != null
                ? Stack(
              children:[
                Image.file(
                  _image!,
                  width:416,
                  height: 416,
                  fit:BoxFit.cover,
                ),
                if(_result != null)
                  Positioned.fill(
                    child:CustomPaint(
                      painter: BoundingBoxPainter(
                        imageSize: const Size(416,416),
                        detection: _result!,
                      ),
                    ),
                  ),
              ],
            ): (cameraController != null && cameraController!.value.isInitialized)?
                SizedBox(
                    child:CameraPreview(cameraController!),
                ): SizedBox(
                    width: 416,
                    height: 416,
                    child: Container(),
                  ),
            CustomButton('Pick from Gallery', () => getImage(ImageSource.gallery)),
            CustomButton('Open Camera', () {
              if(_image!=null){
                setState(() {
                   _batchResults.clear();
                  _image=null;
                  _result=null;
                });
              }
              loadCamera();
            }),
            CustomButton('Select Batch', () async {  // for batch selection
              batch=await selectImageBatch();
              if(batch.isNotEmpty){
                _image=null;
                print("---------------------Selected images in batch: ${batch.length}");
                print(batch);
              }
            }),
            if(_result != null)
              Text(
                conf >= 0.3 ? 'Detected' :'No Detections',
                style: const TextStyle(fontSize: 20),
              ),
          ],
        ),
      ),
    );
  }
}

class CustomButton extends StatelessWidget {
  final String title;
  final VoidCallback onClick;

  CustomButton(this.title, this.onClick);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      child: ElevatedButton(
        onPressed: onClick,
        child: Align(
          alignment: Alignment.center,
          child: Text(title),
        ),
      ),
    );
  }
}

//--------------------bounding boxes------------------------
void drawBoundingBox(Canvas canvas, Size imageSize, List<List<double>> detections) {
  for (var detection in detections) {
    double x = detection[0];
    double y = detection[1];
    double w = detection[2];
    double h = detection[3];
    double confidence = detection[4];

    if (confidence >= 0.3) {
      // Scale the coordinates to match the image dimensions
      double imageWidth = imageSize.width;
      double imageHeight = imageSize.height;

      x *= imageWidth;
      y *= imageHeight;
      w *= imageWidth;
      h *= imageHeight;

      double left = x - w / 2;
      double top = y - h / 2;
      double right = x + w / 2;
      double bottom = y + h / 2;

      // Create a paint object to define the bounding box style
      Paint paint = Paint()
        ..color = Colors.green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), paint);

      //text
      TextStyle textStyle =const TextStyle(
        color: Colors.white,
        fontSize: 16.0,
        fontWeight: FontWeight.bold,
        backgroundColor: Colors.green,
      );
      TextSpan textSpan = TextSpan(
        text: '${(confidence * 100).toStringAsFixed(2)}%',
        style: textStyle,
      );
      TextPainter textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      double textX = left;
      double textY = top - 20.0;

      textPainter.paint(canvas, Offset(textX, textY));
    } else {
      print("No detections");
    }
  }
}


class BoundingBoxPainter extends CustomPainter{
  final Size imageSize;
  final List<List<double>> detection;

  BoundingBoxPainter({
    required this.imageSize,
    required this.detection,
  });

  @override
  void paint(Canvas canvas,Size size){
    drawBoundingBox(canvas,imageSize,detection);
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}
