import 'package:json_annotation/json_annotation.dart';

part 'model_007.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model007 {
  const Model007({required this.id, required this.value});

  final int id;
  final String value;

  factory Model007.fromJson(Map<String, dynamic> json) =>
      _$Model007FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model007ToJson(this);
}
