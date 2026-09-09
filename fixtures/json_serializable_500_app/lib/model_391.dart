import 'package:json_annotation/json_annotation.dart';

part 'model_391.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model391 {
  const Model391({required this.id, required this.value});

  final int id;
  final String value;

  factory Model391.fromJson(Map<String, dynamic> json) =>
      _$Model391FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model391ToJson(this);
}
