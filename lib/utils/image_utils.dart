import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

class ImageUtils {
  /// Converts a [CameraImage] in YUV420 format to [img.Image] in RGB format
  static img.Image? convertCameraImage(CameraImage image) {
    if (image.format.group == ImageFormatGroup.yuv420) {
      return _convertYUV420(image);
    } else if (image.format.group == ImageFormatGroup.bgra8888) {
      return _convertBGRA8888(image);
    }
    return null;
  }

  static img.Image _convertBGRA8888(CameraImage image) {
    return img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: image.planes[0].bytes.buffer,
      order: img.ChannelOrder.bgra,
    );
  }

  static img.Image _convertYUV420(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final uvRowStride = image.planes[1].bytesPerRow;
    final uvPixelStride = image.planes[1].bytesPerPixel ?? 1;

    final img.Image convertedImage = img.Image(width: width, height: height);

    for (int y = 0; y < height; y++) {
      final int uvRowIndex = uvRowStride * (y >> 1);
      final int index = y * width;
      final int uvIndex = uvRowIndex;

      for (int x = 0; x < width; x++) {
        final int uvPixelIndex = uvPixelStride * (x >> 1);
        final int yp = image.planes[0].bytes[index + x];

        // Use safe index access
        final int uvPos = uvIndex + uvPixelIndex;
        if (uvPos >= image.planes[1].bytes.length ||
            uvPos >= image.planes[2].bytes.length) {
          continue;
        }

        final int up = image.planes[1].bytes[uvPos];
        final int vp = image.planes[2].bytes[uvPos];

        int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
        int g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91)
            .round()
            .clamp(0, 255);
        int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);

        convertedImage.setPixelRgb(x, y, r, g, b);
      }
    }
    return convertedImage;
  }
}
