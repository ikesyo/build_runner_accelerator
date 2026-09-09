import 'package:json_annotation/json_annotation.dart';

part 'model_087.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model087 {
  const Model087({required this.id, required this.value});

  final int id;
  final String value;

  factory Model087.fromJson(Map<String, dynamic> json) =>
      _$Model087FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model087ToJson(this);
}
