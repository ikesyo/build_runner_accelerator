import 'package:json_annotation/json_annotation.dart';

part 'model_296.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model296 {
  const Model296({required this.id, required this.value});

  final int id;
  final String value;

  factory Model296.fromJson(Map<String, dynamic> json) =>
      _$Model296FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model296ToJson(this);
}
