import 'package:json_annotation/json_annotation.dart';

part 'model_324.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model324 {
  const Model324({required this.id, required this.value});

  final int id;
  final String value;

  factory Model324.fromJson(Map<String, dynamic> json) =>
      _$Model324FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model324ToJson(this);
}
