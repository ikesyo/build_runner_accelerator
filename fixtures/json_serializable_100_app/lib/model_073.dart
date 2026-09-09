import 'package:json_annotation/json_annotation.dart';

part 'model_073.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model073 {
  const Model073({required this.id, required this.value});

  final int id;
  final String value;

  factory Model073.fromJson(Map<String, dynamic> json) =>
      _$Model073FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model073ToJson(this);
}
