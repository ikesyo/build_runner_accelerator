import 'package:json_annotation/json_annotation.dart';

part 'model_242.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model242 {
  const Model242({required this.id, required this.value});

  final int id;
  final String value;

  factory Model242.fromJson(Map<String, dynamic> json) =>
      _$Model242FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model242ToJson(this);
}
