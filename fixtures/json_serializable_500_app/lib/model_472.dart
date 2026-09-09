import 'package:json_annotation/json_annotation.dart';

part 'model_472.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model472 {
  const Model472({required this.id, required this.value});

  final int id;
  final String value;

  factory Model472.fromJson(Map<String, dynamic> json) =>
      _$Model472FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model472ToJson(this);
}
