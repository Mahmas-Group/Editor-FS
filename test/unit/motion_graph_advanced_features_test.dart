import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capcut_video_editor/domain/models/keyframe.dart';
import 'package:capcut_video_editor/ui/features/editor/view_models/editor_view_model.dart';
import 'package:capcut_video_editor/ui/features/editor/views/widgets/motion_graph_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Mathematical Correctness & Numerical Boundary Tests', () {
    test('EasingCurve handles NaN, Infinity, and extreme t values without crashing', () {
      final curve = EasingCurve.cubic(0.25, 0.1, 0.25, 1.0);

      expect(curve.evaluate(double.nan), equals(0.0));
      expect(curve.evaluate(double.infinity), equals(1.0));
      expect(curve.evaluate(double.negativeInfinity), equals(0.0));

      expect(curve.evaluateDerivative(double.nan), equals(0.0));
      expect(curve.evaluateDerivative(double.infinity), equals(0.0));
      expect(curve.evaluateDerivative(double.negativeInfinity), equals(0.0));

      // Negative and > 1.0 values clamped safely
      expect(curve.evaluate(-5.0), closeTo(0.0, 1e-4));
      expect(curve.evaluate(5.0), closeTo(1.0, 1e-4));
    });

    test('All 14 standard presets evaluate monotonically or with valid overshoots', () {
      for (final preset in EasingCurve.standardPresets) {
        final start = preset.evaluate(0.0);
        final end = preset.evaluate(1.0);
        expect(start.isFinite, isTrue, reason: '${preset.displayName} start');
        expect(end.isFinite, isTrue, reason: '${preset.displayName} end');

        // Sample at 50 points to check for finite evaluation and derivatives
        for (int i = 0; i <= 50; i++) {
          final t = i / 50.0;
          final val = preset.evaluate(t);
          final deriv = preset.evaluateDerivative(t);
          expect(val.isFinite, isTrue, reason: '${preset.displayName} val at $t');
          expect(deriv.isFinite, isTrue, reason: '${preset.displayName} deriv at $t');
        }
      }
    });

    test('Cubic Bezier handles degenerate handles (collinear, zero distance) robustly', () {
      final degenerate = EasingCurve.cubic(0.0, 0.0, 0.0, 0.0);
      expect(degenerate.evaluate(0.0), closeTo(0.0, 1e-4));
      expect(degenerate.evaluate(1.0), closeTo(1.0, 1e-4));
      expect(degenerate.evaluate(0.5).isFinite, isTrue);

      final reversed = EasingCurve.cubic(1.0, 1.0, 0.0, 0.0);
      expect(reversed.evaluate(0.5).isFinite, isTrue);
    });
  });

  group('Temporal Manipulation & Track Operations Tests', () {
    test('KeyframeTrackGroup.shiftPropertyTime shifts only targeted property', () {
      var group = const KeyframeTrackGroup();
      group = group.addKeyframe(AnimatableProperty.scale, 500, 1.0);
      group = group.addKeyframe(AnimatableProperty.scale, 1500, 2.0);
      group = group.addKeyframe(AnimatableProperty.rotation, 500, 45.0);

      final shifted = group.shiftPropertyTime(AnimatableProperty.scale, 500);

      // Scale track shifted by +500ms
      final scaleTrack = shifted.tracks[AnimatableProperty.scale]!;
      expect(scaleTrack.keyframes[0].timestampMs, equals(1000));
      expect(scaleTrack.keyframes[1].timestampMs, equals(2000));

      // Rotation track left completely untouched
      final rotTrack = shifted.tracks[AnimatableProperty.rotation]!;
      expect(rotTrack.keyframes[0].timestampMs, equals(500));
    });

    test('KeyframeTrackGroup.scalePropertyTime scales only targeted property around anchor', () {
      var group = const KeyframeTrackGroup();
      group = group.addKeyframe(AnimatableProperty.scale, 1000, 1.0);
      group = group.addKeyframe(AnimatableProperty.scale, 2000, 2.0);
      group = group.addKeyframe(AnimatableProperty.opacity, 1000, 0.5);

      // Scale by 2.0 around anchor 1000ms
      final scaled = group.scalePropertyTime(AnimatableProperty.scale, 2.0, originMs: 1000);

      final scaleTrack = scaled.tracks[AnimatableProperty.scale]!;
      expect(scaleTrack.keyframes[0].timestampMs, equals(1000));
      expect(scaleTrack.keyframes[1].timestampMs, equals(3000)); // (2000-1000)*2 + 1000

      // Opacity track untouched
      final opacityTrack = scaled.tracks[AnimatableProperty.opacity]!;
      expect(opacityTrack.keyframes[0].timestampMs, equals(1000));
    });

    test('Scale factor <= 0 or zero length behaves safely without throwing', () {
      var group = const KeyframeTrackGroup();
      group = group.addKeyframe(AnimatableProperty.scale, 1000, 1.0);

      final scaledZero = group.scalePropertyTime(AnimatableProperty.scale, 0.0);
      expect(scaledZero.tracks[AnimatableProperty.scale]!.keyframes[0].timestampMs, equals(1000));

      final scaledNeg = group.scalePropertyTime(AnimatableProperty.scale, -1.5);
      expect(scaledNeg.tracks[AnimatableProperty.scale]!.keyframes[0].timestampMs, equals(1000));
    });
  });

  group('EditorViewModel Gesture Transaction & Temporal Methods Tests', () {
    test('Gesture transaction captures single snapshot across multiple drag updates', () {
      final viewModel = EditorViewModel(enableMockFallback: false);
      viewModel.addNewClipFromMedia(
        assetId: 'gesture_test_clip',
        title: 'Gesture Clip',
        duration: const Duration(seconds: 10),
        gradient: [Colors.black, Colors.white],
      );

      viewModel.seekTo(1.0);
      viewModel.addKeyframeAtPlayhead();

      expect(viewModel.canUndo, isTrue);
      // Clear undo history by tracking initial count
      int undosBeforeGesture = 0;
      while (viewModel.canUndo) {
        viewModel.undo();
        undosBeforeGesture++;
      }
      // Re-add keyframe
      viewModel.seekTo(1.0);
      viewModel.addKeyframeAtPlayhead();

      // Begin gesture
      viewModel.beginKeyframeGesture();

      // Simulate 10 live continuous drag updates with saveSnapshot: false
      for (int i = 1; i <= 10; i++) {
        viewModel.updateKeyframeBezierHandles(
          AnimatableProperty.scale,
          1000,
          0.1 * i,
          0.2,
          0.8,
          0.9,
          saveSnapshot: false,
        );
      }

      // End gesture
      viewModel.endKeyframeGesture();

      // Verify undo stack: only 1 undo operation was recorded for the whole gesture!
      expect(viewModel.canUndo, isTrue);
      viewModel.undo();
      // After single undo, it should restore to pre-gesture state
      expect(viewModel.canRedo, isTrue);
    });

    test('shiftKeyframeTrack shifts track and integrates with undo/redo', () {
      final viewModel = EditorViewModel(enableMockFallback: false);
      viewModel.addNewClipFromMedia(
        assetId: 'shift_vm_clip',
        title: 'Shift Clip',
        duration: const Duration(seconds: 10),
        gradient: [Colors.green, Colors.blue],
      );

      viewModel.seekTo(2.0);
      viewModel.addKeyframeAtPlayhead();

      // Shift scale track by +1000ms
      viewModel.shiftKeyframeTrack(AnimatableProperty.scale, 1000);

      var track = viewModel.selectedClip?.effectiveKeyframeTracks.tracks[AnimatableProperty.scale];
      expect(track?.keyframes.first.timestampMs, equals(3000));

      // Undo restores original 2000ms position
      expect(viewModel.canUndo, isTrue);
      viewModel.undo();
      track = viewModel.selectedClip?.effectiveKeyframeTracks.tracks[AnimatableProperty.scale];
      expect(track?.keyframes.first.timestampMs, equals(2000));

      // Redo restores 3000ms position
      viewModel.redo();
      track = viewModel.selectedClip?.effectiveKeyframeTracks.tracks[AnimatableProperty.scale];
      expect(track?.keyframes.first.timestampMs, equals(3000));
    });

    test('applyEasingToTrack applies curve across all keyframes on track', () {
      final viewModel = EditorViewModel(enableMockFallback: false);
      viewModel.addNewClipFromMedia(
        assetId: 'easing_track_clip',
        title: 'Track Easing Clip',
        duration: const Duration(seconds: 10),
        gradient: [Colors.purple, Colors.pink],
      );

      viewModel.seekTo(1.0);
      viewModel.addKeyframeAtPlayhead();
      viewModel.seekTo(3.0);
      viewModel.addKeyframeAtPlayhead();

      // Apply easeInOutCubic to scale track
      viewModel.applyEasingToTrack(
        AnimatableProperty.scale,
        EasingCurve.easeInOutCubic,
        syncAllTransformProperties: false,
      );

      final track = viewModel.selectedClip?.effectiveKeyframeTracks.tracks[AnimatableProperty.scale];
      expect(track?.keyframes[0].easing.mode, equals(InterpolationMode.cubicBezier));
      expect(track?.keyframes[0].easing.x1, closeTo(0.65, 1e-3));
      expect(track?.keyframes[1].easing.mode, equals(InterpolationMode.cubicBezier));
    });
  });

  group('MotionGraphCoordinates Zoom & Math Tests', () {
    test('Viewport zoom correctly bounds and maps coordinates deterministically', () {
      const track = KeyframeTrack(
        property: AnimatableProperty.scale,
        keyframes: [
          MotionKeyframe(id: 'k0', timestampMs: 1000, value: 1.0),
          MotionKeyframe(id: 'k1', timestampMs: 3000, value: 2.0),
        ],
      );

      // Standard full-view coordinates
      final fullCoords = MotionGraphCoordinates(
        size: const Size(400, 200),
        track: track,
        durationSec: 10.0,
        property: AnimatableProperty.scale,
        viewStartSec: 0.0,
        viewEndSec: 10.0,
      );

      expect(fullCoords.timeToX(0.0), closeTo(0.0, 1e-3));
      expect(fullCoords.timeToX(10.0), closeTo(400.0, 1e-3));
      expect(fullCoords.xToTime(0.0), closeTo(0.0, 1e-3));
      expect(fullCoords.xToTime(400.0), closeTo(10.0, 1e-3));

      // Zoomed viewport (2.0s to 4.0s)
      final zoomCoords = MotionGraphCoordinates(
        size: const Size(400, 200),
        track: track,
        durationSec: 10.0,
        property: AnimatableProperty.scale,
        viewStartSec: 2.0,
        viewEndSec: 4.0,
      );

      expect(zoomCoords.timeToX(2.0), closeTo(0.0, 1e-3));
      expect(zoomCoords.timeToX(4.0), closeTo(400.0, 1e-3));
      expect(zoomCoords.xToTime(200.0), closeTo(3.0, 1e-3));
    });
  });
}
