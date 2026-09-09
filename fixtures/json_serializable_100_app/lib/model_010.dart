import 'package:json_annotation/json_annotation.dart';

part 'model_010.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model010 {
  const Model010({required this.id, required this.value});

  final int id;
  final String value;

  factory Model010.fromJson(Map<String, dynamic> json) =>
      _$Model010FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model010ToJson(this);
}
