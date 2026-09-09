import 'package:json_annotation/json_annotation.dart';

part 'model_363.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model363 {
  const Model363({required this.id, required this.value});

  final int id;
  final String value;

  factory Model363.fromJson(Map<String, dynamic> json) =>
      _$Model363FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model363ToJson(this);
}
