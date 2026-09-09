import 'package:json_annotation/json_annotation.dart';

part 'model_218.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model218 {
  const Model218({required this.id, required this.value});

  final int id;
  final String value;

  factory Model218.fromJson(Map<String, dynamic> json) =>
      _$Model218FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model218ToJson(this);
}
