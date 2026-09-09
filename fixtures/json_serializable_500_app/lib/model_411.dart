import 'package:json_annotation/json_annotation.dart';

part 'model_411.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model411 {
  const Model411({required this.id, required this.value});

  final int id;
  final String value;

  factory Model411.fromJson(Map<String, dynamic> json) =>
      _$Model411FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model411ToJson(this);
}
