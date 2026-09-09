import 'package:json_annotation/json_annotation.dart';

part 'model_395.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model395 {
  const Model395({required this.id, required this.value});

  final int id;
  final String value;

  factory Model395.fromJson(Map<String, dynamic> json) =>
      _$Model395FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model395ToJson(this);
}
