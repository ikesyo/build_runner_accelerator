import 'package:json_annotation/json_annotation.dart';

part 'model_483.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model483 {
  const Model483({required this.id, required this.value});

  final int id;
  final String value;

  factory Model483.fromJson(Map<String, dynamic> json) =>
      _$Model483FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model483ToJson(this);
}
